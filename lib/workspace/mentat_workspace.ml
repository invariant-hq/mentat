(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Root = Root
module Error = Error
module Resolve_error = Resolve_error
module Path = Path
module Notice = Notice
module Health = Health

type t = { primary : Root.t; read_only : Root.t list; cwd : Path.t }

let roots t = t.primary :: t.read_only
let primary t = t.primary
let read_only_roots t = t.read_only
let is_writable t root = Root.equal root t.primary

let root_by_key t key =
  List.find_opt (fun root -> Root.Key.equal (Root.key root) key) (roots t)

let contains_path t path = Option.is_some (root_by_key t (Path.root_key path))

let is_writable_path t path =
  Root.Key.equal (Path.root_key path) (Root.key t.primary)

let to_abs t path =
  match root_by_key t (Path.root_key path) with
  | Some root -> Ok (Lpath.Abs.append_rel (Root.dir root) (Path.rel path))
  | None -> Error (Resolve_error.Unknown_root (Path.root_key path))

let admit_auxiliaries ~primary read_only =
  let same_dir a b = Lpath.Abs.equal (Root.dir a) (Root.dir b) in
  let conflicts_with root existing =
    Root.same_key existing root || same_dir existing root
  in
  let rec loop admitted = function
    | [] -> Ok (List.rev admitted)
    | root :: rest -> (
        let earlier = primary :: List.rev admitted in
        match List.find_opt (conflicts_with root) earlier with
        | None -> loop (root :: admitted) rest
        | Some existing ->
            if Root.equal existing root then loop admitted rest
            else Error (Error.Conflicting_root { existing; duplicate = root }))
  in
  loop [] read_only

let make ?cwd ~primary ~read_only () =
  match admit_auxiliaries ~primary read_only with
  | Error _ as error -> error
  | Ok read_only ->
      let default_cwd = Path.make ~root_key:(Root.key primary) Lpath.Rel.root in
      let cwd = Option.value cwd ~default:default_cwd in
      let workspace = { primary; read_only; cwd } in
      if contains_path workspace cwd then Ok workspace
      else Error (Error.Root_not_in_workspace (Path.root_key cwd))

let single ?(cwd = Lpath.Rel.root) root =
  {
    primary = root;
    read_only = [];
    cwd = Path.make ~root_key:(Root.key root) cwd;
  }

let cwd t = t.cwd
let root_path t = Path.make ~root_key:(Root.key t.primary) Lpath.Rel.root
let path_at_cwd_root t rel = Path.make ~root_key:(Path.root_key t.cwd) rel
let specificity root = List.length (Lpath.Abs.components (Root.dir root))

let import_root t abs =
  let more_specific root rel current =
    match current with
    | Some (_, _, best) when specificity root <= best -> current
    | _ -> Some (root, rel, specificity root)
  in
  let choose best root =
    match Lpath.Abs.relativize ~root:(Root.dir root) abs with
    | None -> best
    | Some rel -> more_specific root rel best
  in
  Option.map
    (fun (root, rel, _) -> Path.make ~root_key:(Root.key root) rel)
    (List.fold_left choose None (roots t))

let import_abs t abs =
  match import_root t abs with
  | Some path -> Ok path
  | None -> Error (Resolve_error.Outside_workspace abs)

let cwd_abs t =
  match to_abs t t.cwd with Ok abs -> abs | Error _ -> assert false

let resolve_string t input =
  let resolved =
    if (not (String.is_empty input)) && Char.equal input.[0] '/' then
      Lpath.Abs.of_string input
    else Lpath.Abs.resolve (cwd_abs t) input
  in
  match resolved with
  | Error error -> Error (Resolve_error.Invalid_input error)
  | Ok abs -> import_abs t abs

let equal a b =
  Root.equal a.primary b.primary
  && List.equal Root.equal a.read_only b.read_only
  && Path.equal a.cwd b.cwd

let pp_roots ppf roots =
  Format.pp_print_list
    ~pp_sep:(fun ppf () -> Format.pp_print_string ppf "; ")
    Root.pp ppf roots

let pp ppf t =
  Format.fprintf ppf "@[<2>{ primary = %a;@ read_only = [%a];@ cwd = %a }@]"
    Root.pp t.primary pp_roots t.read_only Path.pp t.cwd

let protected_meta_names = [ ".git"; ".mentat" ]

let protected_meta_component path =
  match Lpath.Rel.components (Path.rel path) with
  | first :: _ when List.exists (String.equal first) protected_meta_names ->
      Some first
  | _ -> None

let observation_prune_names = [ ".git"; ".mentat"; "_build"; "_opam" ]
