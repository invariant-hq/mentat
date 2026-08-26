(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

let invalid fn message = Import.invalid_arg' "Mentat_store.Handle" fn message

module Registry = struct
  type keyed = { mutex : Eio.Mutex.t; mutable users : int }

  (* A reservation witness: minted by [try_reserve], carried by the guard whose
     acquisition it admitted. Identity ([==]) names the holder; the cell's value
     records confirmation — [false] pending, [true] held. *)
  type token = bool ref

  type t = {
    guard : Mutex.t;
    keyed : (string, keyed) Hashtbl.t;
    reservations : (string, token * Owner.t) Hashtbl.t;
  }

  let create () =
    {
      guard = Mutex.create ();
      keyed = Hashtbl.create 8;
      reservations = Hashtbl.create 8;
    }

  (* [users] counts owners and waiters before either can block; the last one
     removes the entry, keeping the table proportional to live critical sections
     rather than every key the process has ever touched. *)
  let with_keyed t key f =
    let entry =
      Mutex.protect t.guard (fun () ->
          match Hashtbl.find_opt t.keyed key with
          | Some entry ->
              entry.users <- entry.users + 1;
              entry
          | None ->
              let entry = { mutex = Eio.Mutex.create (); users = 1 } in
              Hashtbl.add t.keyed key entry;
              entry)
    in
    Fun.protect
      ~finally:(fun () ->
        Mutex.protect t.guard (fun () ->
            entry.users <- entry.users - 1;
            if entry.users = 0 then Hashtbl.remove t.keyed key))
      (fun () -> Eio.Mutex.use_ro entry.mutex f)

  let try_reserve t key owner =
    Mutex.protect t.guard (fun () ->
        match Hashtbl.find_opt t.reservations key with
        | Some (_, holder) -> Error holder
        | None ->
            let token = ref false in
            Hashtbl.add t.reservations key (token, owner);
            Ok token)

  let confirm t token = Mutex.protect t.guard (fun () -> token := true)

  let cancel t key token =
    Mutex.protect t.guard (fun () ->
        match Hashtbl.find_opt t.reservations key with
        | Some (current, _) when current == token ->
            Hashtbl.remove t.reservations key
        | Some _ | None -> ())

  let holds t key token =
    Mutex.protect t.guard (fun () ->
        match Hashtbl.find_opt t.reservations key with
        | Some (current, _) -> current == token && !current
        | None -> false)

  let holder t key =
    Mutex.protect t.guard (fun () ->
        Option.map snd (Hashtbl.find_opt t.reservations key))
end

(* The process-local intern table: physical root identity to registry, scoped to
   root lifetime. Entries are reference-counted and removed when the last open
   over a root is released, so the table stays proportional to live roots and a
   recycled inode pair cannot inherit a dead root's registry. *)

type interned = { shared : Registry.t; mutable refs : int }

let interned : (Int64.t * Int64.t, interned) Hashtbl.t = Hashtbl.create 4
let interned_guard = Mutex.create ()

let acquire_registry identity =
  Mutex.protect interned_guard (fun () ->
      match Hashtbl.find_opt interned identity with
      | Some entry ->
          entry.refs <- entry.refs + 1;
          entry.shared
      | None ->
          let entry = { shared = Registry.create (); refs = 1 } in
          Hashtbl.add interned identity entry;
          entry.shared)

let release_registry identity =
  Mutex.protect interned_guard (fun () ->
      match Hashtbl.find_opt interned identity with
      | Some (entry : interned) ->
          entry.refs <- entry.refs - 1;
          if entry.refs <= 0 then Hashtbl.remove interned identity
      | None -> ())

type t = {
  dir : Eio.Fs.dir_ty Eio.Path.t;
  root : string;
      (** The root's native path as opened — for external tooling that stats a
          sidecar artifact by absolute path (best-effort; never a store op). *)
  registry : Registry.t;
}

let path t rel = Eio.Path.( / ) t.dir rel
let native t rel = Filename.concat t.root rel
let registry (t : t) = t.registry

type guard = {
  session : Mentat_session.Id.t;
  owner : Owner.t;
  fd : Eio_unix.Fd.t;
  root_registry : Registry.t;
  key : string;
  token : Registry.token;
  anchor : Mentat_mutation.State.t option ref;
  released : bool Atomic.t;
}

let check_live (t : t) (guard : guard) =
  if Atomic.get guard.released then invalid "check_live" "guard is released";
  if not (guard.root_registry == t.registry) then
    invalid "check_live" "guard is for a different store root";
  if not (Registry.holds guard.root_registry guard.key guard.token) then
    invalid "check_live" "guard does not hold this store root's run lock"

(* A layout child that exists and is not a directory: adopting it would misplace
   every op under it. *)
exception Layout_child of string

let ensure_child t ~root_label child =
  match Eio.Path.kind ~follow:true (path t child) with
  | `Directory -> ()
  | `Not_found ->
      if Disk.mkdir ~path:child (path t child) then
        Disk.fsync_dir ~path:root_label t.dir
  | _ -> raise (Layout_child child)
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn -> Disk.raise_io ~op:Io.Read ~path:child exn

let open_ ~sw path ~children =
  let root_label =
    match Eio.Path.native path with Some s -> s | None -> "."
  in
  match
    let dir =
      match Eio.Path.open_subtree ~sw path with
      | dir -> (dir :> Eio.Fs.dir_ty Eio.Path.t)
      | exception exn -> Disk.raise_io ~op:Io.Open ~path:root_label exn
    in
    let stat =
      match Eio.Path.stat ~follow:true dir with
      | stat -> stat
      | exception exn -> Disk.raise_io ~op:Io.Read ~path:root_label exn
    in
    let identity = (stat.Eio.File.Stat.dev, stat.Eio.File.Stat.ino) in
    let registry = acquire_registry identity in
    Eio.Switch.on_release sw (fun () -> release_registry identity);
    let t : t = { dir; root = root_label; registry } in
    List.iter (ensure_child t ~root_label) children;
    t
  with
  | t -> Ok t
  | exception Layout_child child ->
      Error (`Layout (child, "layout child is not a directory"))
  | exception Disk.Io_error payload -> Error (`Io payload)
