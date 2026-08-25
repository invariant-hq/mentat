(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Instance = Mentat_ocaml_dune_rpc.Instance

let realpath_or path =
  match Unix.realpath path with p -> p | exception Unix.Unix_error _ -> path

(* Canonicalise: Dune registers its RPC endpoint under the realpath of the
   root, and the instance matches endpoints against the workspace root after
   [realpath]; on macOS the temp directory is a [/var/...] path that is a
   symlink to [/private/var/...]. *)
let with_temp_dir f =
  f (realpath_or (temp_dir ~prefix:"mentat-dune-rpc-test" ()))

let write_file path contents =
  Out_channel.with_open_bin path (fun oc ->
      Out_channel.output_string oc contents)

let make_project ~root ~broken =
  Unix.mkdir (Filename.concat root "lib") 0o755;
  write_file (Filename.concat root "dune-project") "(lang dune 3.22)\n";
  write_file (Filename.concat root "lib/dune") "(library\n (name probe_lib))\n";
  write_file
    (Filename.concat root "lib/probe_lib.ml")
    (if broken then "let (x : int) = \"deliberate type error\"\n"
     else "let x = 42\nlet () = ignore x\n")

let workspace_at root =
  Mentat_workspace.single
    (Mentat_workspace.Root.of_dir (Lpath.Abs.of_string_exn root))

(* Spawn a real [dune build --root <root> --watch @check], killed when [sw]
   ends. Stdout/stderr are shell-redirected to /dev/null so the watch's chatter
   stays out of the test log. [ocamlc]'s directory is placed on the child's
   PATH so the watch has a compiler regardless of how it was discovered. *)
let spawn_watch ~sw ~env ~toolchain ~dune ~root =
  let child_env = Mentat_ocaml_toolchain.env toolchain ~program:"ocamlc" in
  let command =
    [
      "/bin/sh";
      "-c";
      "exec \"$1\" build --root \"$2\" --watch @check >/dev/null 2>&1";
      "sh";
      dune;
      root;
    ]
  in
  let process =
    Eio.Process.spawn ~sw
      (Eio.Stdenv.process_mgr env)
      ~cwd:(Eio.Path.( / ) (Eio.Stdenv.fs env) root)
      ~stdin:(Eio.Flow.string_source "")
      ~env:child_env command
  in
  Eio.Switch.on_release sw (fun () ->
      (try Eio.Process.signal process Sys.sigkill with _ -> ());
      match Unix.kill (Eio.Process.pid process) Sys.sigkill with
      | () | (exception Unix.Unix_error _) -> ());
  process

(* Run [attach] in a sibling fiber for the duration of [f]: the loop never
   returns, so the race ends it when [f]'s branch finishes. *)
let with_attached instance f =
  Eio.Fiber.first
    (fun () ->
      Instance.attach instance;
      assert false)
    f

(* Poll [snapshot] until [wanted] accepts it or the deadline passes; return the
   last snapshot seen. A found-but-not-yet-built watch is transiently detached
   or building, so we wait for the target rather than trusting the first. *)
let await_snapshot ~clock instance ~wanted ~timeout_s =
  let deadline = Eio.Time.now clock +. timeout_s in
  let rec loop () =
    let snapshot = Instance.snapshot instance in
    if wanted snapshot || Eio.Time.now clock >= deadline then snapshot
    else begin
      Eio.Time.sleep clock 0.1;
      loop ()
    end
  in
  loop ()

(* Hermetic: with no watch registered for a fresh workspace, the snapshot is
   [Absent] with no reading — before the attach loop runs, and after it has
   polled the registry for a while. The loop never blocks its caller: the
   snapshot is a memory read on any fiber. *)
let snapshot_absent () =
  with_temp_dir @@ fun root ->
  make_project ~root ~broken:true;
  Eio_main.run @@ fun eio_env ->
  let instance =
    Instance.create ~fs:(Eio.Stdenv.fs eio_env) ~net:(Eio.Stdenv.net eio_env)
      ~mono:(Eio.Stdenv.mono_clock eio_env) ~workspace:(workspace_at root) ()
  in
  let before = Instance.snapshot instance in
  is_true ~msg:"absent before attach"
    (Instance.Status.equal before.Instance.Snapshot.status Instance.Status.Absent);
  is_true ~msg:"no reading before attach"
    (Option.is_none before.Instance.Snapshot.reading);
  let clock = Eio.Stdenv.clock eio_env in
  with_attached instance (fun () ->
      let snapshot =
        await_snapshot ~clock instance ~timeout_s:1.0 ~wanted:(fun _ -> false)
      in
      is_true
        ~msg:
          (Format.asprintf "no watch registered => Absent, got %a"
             Instance.Status.pp snapshot.Instance.Snapshot.status)
        (Instance.Status.equal snapshot.Instance.Snapshot.status
           Instance.Status.Absent))

(* Live end-to-end: attach to a real running Dune and confirm the handshake,
   the subscriptions, and the settled reading are truthful — a failing verdict
   for a type-erroring project, a clean one for a good project.

   Opt-in via [MENTAT_DUNE_RPC_LIVE_TEST]: it spawns real [dune build --watch]
   processes and reads Dune's XDG RPC registry, which the [dune runtest] sandbox
   isolates (registry entries a spawned watch writes are not observable from
   inside it). Left ungated it would flake or fail there, so the default suite
   skips it; a developer runs it directly with a compiler on PATH
   ([MENTAT_DUNE_RPC_LIVE_TEST=1 dune exec test/unit/test_ocaml_dune_rpc.exe])
   to exercise the real client handshake and long-polls — the concern the
   reducible unit tests cannot reach. *)
let attach_live () =
  match Sys.getenv_opt "MENTAT_DUNE_RPC_LIVE_TEST" with
  | None | Some "" | Some "0" ->
      Printf.eprintf
        "[skip] live Dune RPC attach: set MENTAT_DUNE_RPC_LIVE_TEST=1 (with \
         dune + ocamlc discoverable) to exercise the live handshake\n\
         %!"
  | Some _ -> (
      let toolchain =
        Mentat_ocaml_toolchain.discover ~env:(Unix.environment ())
          ~workspace_root:None
      in
      match
        ( Mentat_ocaml_toolchain.find toolchain "dune",
          Mentat_ocaml_toolchain.find toolchain "ocamlc" )
      with
      | Some (dune, _), Some (_ocamlc, _) ->
          Eio_main.run @@ fun eio_env ->
          let fs = Eio.Stdenv.fs eio_env in
          let net = Eio.Stdenv.net eio_env in
          let clock = Eio.Stdenv.clock eio_env in
          let settled_verdict (snapshot : Instance.Snapshot.t) =
            match snapshot.Instance.Snapshot.reading with
            | Some reading when not snapshot.Instance.Snapshot.building ->
                Some (Mentat_ocaml.Build_change.Reading.verdict reading)
            | Some _ | None -> None
          in
          let check ~broken ~wanted ~label =
            with_temp_dir @@ fun root ->
            make_project ~root ~broken;
            Eio.Switch.run @@ fun sw ->
            let _watch = spawn_watch ~sw ~env:eio_env ~toolchain ~dune ~root in
            let instance =
              Instance.create ~fs ~net ~mono:(Eio.Stdenv.mono_clock eio_env)
                ~workspace:(workspace_at root) ()
            in
            with_attached instance (fun () ->
                let snapshot =
                  await_snapshot ~clock instance ~timeout_s:20.0
                    ~wanted:(fun snapshot ->
                      match settled_verdict snapshot with
                      | Some verdict -> wanted verdict
                      | None -> false)
                in
                is_true
                  ~msg:
                    (Format.asprintf "%s: expected %s, got %a / %s" label
                       (if broken then "Failing" else "Clean")
                       Instance.Status.pp snapshot.Instance.Snapshot.status
                       (match settled_verdict snapshot with
                       | Some verdict ->
                           Format.asprintf "%a"
                             Mentat_workspace.Health.Verdict.pp verdict
                       | None -> "no settled reading"))
                  (match settled_verdict snapshot with
                  | Some verdict -> wanted verdict
                  | None -> false))
          in
          check ~broken:true ~label:"broken project" ~wanted:(function
            | Mentat_workspace.Health.Verdict.Failing { errors; _ } ->
                errors >= 1
            | Mentat_workspace.Health.Verdict.Clean -> false);
          check ~broken:false ~label:"clean project" ~wanted:(function
            | Mentat_workspace.Health.Verdict.Clean -> true
            | Mentat_workspace.Health.Verdict.Failing _ -> false)
      | _ ->
          failf
            "MENTAT_DUNE_RPC_LIVE_TEST is set but no dune + ocamlc toolchain \
             is discoverable; put a compiler on PATH or set OPAM_SWITCH_PREFIX")

(* The pure stream fold, table-tested at the production window values the
   hermetic cram cannot reach (it zeroes the quiet window): synthetic
   timestamps drive the quiet rule, the settle witness, and the fallback. *)

module Store = Mentat_ocaml_dune_rpc.Store

let at s = Mtime.of_uint64_ns (Int64.of_float (s *. 1e9))

let err name =
  Mentat_ocaml.Finding.v ~lane:Mentat_ocaml.Finding.Lane.Build
    ~severity:Mentat_ocaml.Finding.Severity.Error ~head:("Unbound value " ^ name)
    ()

let read ?(quiet_s = 0.25) ?(fallback_s = 2.0) store ~now =
  Store.reading store ~now:(at now) ~quiet_s ~fallback_s

let fold events =
  List.fold_left (fun store (t, event) -> Store.apply ~at:(at t) event store)
    Store.initial events

let step_on store ~now state =
  Mentat_ocaml.Build_change.step state (read store ~now)

let store_rules =
  group "store timing rules"
    [
      test "no reading before the first diagnostic answer" (fun () ->
          let store =
            fold [ (0., Store.Connected); (0.1, Store.Progress `Settle) ]
          in
          is_true ~msg:"unsynced emptiness is never a reading"
            (Option.is_none (read store ~now:10.)));
      test "an empty first answer synchronises and confirms via the settle"
        (fun () ->
          let store =
            fold
              [
                (0., Store.Connected);
                (0.1, Store.Diagnostics []);
                (0.2, Store.Progress `Settle);
              ]
          in
          match read store ~now:1. with
          | None -> fail "expected a reading"
          | Some reading ->
              let state = Mentat_ocaml.Build_change.State.initial in
              let changes, _ =
                Mentat_ocaml.Build_change.step state (Some reading)
              in
              equal int ~msg:"first-seen clean says nothing" 0
                (List.length changes));
      test "the quiet window gates the reading" (fun () ->
          let store =
            fold
              [
                (0., Store.Connected);
                (0.1, Store.Progress `Settle);
                (1., Store.Diagnostics [ `Add ("1", err "restock") ]);
              ]
          in
          is_true ~msg:"mid-churn is no reading"
            (Option.is_none (read store ~now:1.2));
          is_true ~msg:"at rest is a reading"
            (Option.is_some (read store ~now:1.3)));
      test
        "a sub-sample rebuild's emptiness is withheld until witnessed or the \
         fallback"
        (fun () ->
          let failing =
            fold
              [
                (0., Store.Connected);
                (0.1, Store.Diagnostics [ `Add ("1", err "restock") ]);
                (0.2, Store.Progress `Settle);
              ]
          in
          let _, stated =
            step_on failing ~now:1.
              Mentat_ocaml.Build_change.State.initial
          in
          (* The rebuild empties the store but its settle is coalesced away:
             no progress event arrives, and the witness fell with the
             removal. *)
          let emptied =
            Store.apply ~at:(at 2.) (Store.Diagnostics [ `Remove "1" ]) failing
          in
          let changes, stated' = step_on emptied ~now:2.4 stated in
          equal int ~msg:"unconfirmed emptiness states nothing" 0
            (List.length changes);
          let changes, _ = step_on emptied ~now:4.5 stated' in
          equal (list string) ~msg:"the 2 s fallback confirms it"
            [ "Build recovered" ]
            (List.map
               (fun change ->
                 Mentat_workspace.Notice.title
                   (Mentat_ocaml.Build_change.notice change))
               changes));
      test "a witnessed settle confirms emptiness at once" (fun () ->
          let failing =
            fold
              [
                (0., Store.Connected);
                (0.1, Store.Diagnostics [ `Add ("1", err "restock") ]);
                (0.2, Store.Progress `Settle);
              ]
          in
          let _, stated =
            step_on failing ~now:1.
              Mentat_ocaml.Build_change.State.initial
          in
          let recovered =
            List.fold_left
              (fun store (t, event) -> Store.apply ~at:(at t) event store)
              failing
              [
                (2., Store.Diagnostics [ `Remove "1" ]);
                (2.1, Store.Progress `Settle);
              ]
          in
          let changes, _ = step_on recovered ~now:2.5 stated in
          equal int ~msg:"one change" 1 (List.length changes));
      test "a reconnect restarts the quiet clock" (fun () ->
          let store =
            fold
              [
                (0., Store.Connected);
                (0.1, Store.Diagnostics [ `Add ("1", err "restock") ]);
                (0.2, Store.Progress `Settle);
                (5., Store.Connected);
                (5.1, Store.Progress `Settle);
              ]
          in
          is_true
            ~msg:"the old set is forgotten and nothing reads until re-sync"
            (Option.is_none (read store ~now:9.)));
    ]

module Watch = Mentat_ocaml_dune_rpc.Watch
module Health = Mentat_workspace.Health

let live owner = Health.Live { owner; phase = Health.Phase.Building }

let watch_law =
  group "watch law"
    [
      test "an observed attachment wins, whatever the machine claims"
        (fun () ->
          let observed = live (Health.Owner.Theirs 42) in
          List.iter
            (fun word ->
              is_true ~msg:"an attached connection is ground truth"
                (Health.equal observed (Watch.compose word ~observed)))
            [
              Watch.Defer;
              Watch.Announce Health.Probing;
              Watch.Announce Health.Starting;
              Watch.Announce
                (Health.Restarting (Health.Restart.Exited "exit 1"));
              Watch.Announce (Health.Off Health.Off.Gave_up);
            ]);
      test "Defer hands the observer's view through unchanged" (fun () ->
          List.iter
            (fun observed ->
              is_true ~msg:"the observer speaks"
                (Health.equal observed (Watch.compose Watch.Defer ~observed)))
            [
              Health.Off Health.Off.No_server;
              Health.Probing;
              live Health.Owner.Ours;
            ]);
      test "an announcement outranks a non-live observer" (fun () ->
          List.iter
            (fun observed ->
              is_true ~msg:"the machine's claim shows"
                (Health.equal Health.Starting
                   (Watch.compose (Watch.Announce Health.Starting) ~observed)))
            [ Health.Off Health.Off.No_server; Health.Probing ]);
      test "two consecutive pre-Live deaths give up" (fun () ->
          match Watch.after_death ~reached:false ~deaths:0 with
          | `Give_up -> fail "the first death restarts"
          | `Retry deaths -> (
              equal int ~msg:"one strike" 1 deaths;
              match Watch.after_death ~reached:false ~deaths with
              | `Retry _ -> fail "the second consecutive death gives up"
              | `Give_up -> ()));
      test "the stall predicate reads the program off the command text"
        (fun () ->
          let reported command = Watch.forwards_into_watch ~command in
          List.iter
            (fun command ->
              is_true ~msg:("reports: " ^ command) (reported command))
            [
              "dune build @check";
              "FOO=1 dune build";
              "DUNE_CACHE_ROOT=/tmp/cache dune build";
              "dune\tbuild";
              "/opt/dune/bin/dune build";
            ];
          List.iter
            (fun command ->
              is_false ~msg:("stays silent: " ^ command) (reported command))
            [
              "sleep 2";
              "echo dune";
              (* Wrapped invocations are deliberate misses: a stall they
                 hide surfaces on the next bare dune command. *)
              "timeout 30 dune build";
              "opam exec -- dune build";
              "cd sub && dune build";
              "./x/prog=dune build";
              "";
            ]);
      test "a life that reached Live buys the respawn two fresh strikes"
        (fun () ->
          match Watch.after_death ~reached:true ~deaths:1 with
          | `Give_up -> fail "a reached life's death always restarts"
          | `Retry deaths -> (
              equal int ~msg:"the count is reset, not set to one" 0 deaths;
              match Watch.after_death ~reached:false ~deaths with
              | `Give_up -> fail "the respawn keeps both strikes"
              | `Retry deaths -> (
                  match Watch.after_death ~reached:false ~deaths with
                  | `Give_up -> ()
                  | `Retry _ -> fail "the second strike gives up")));
    ]

let () =
  run "mentat.ocaml.dune_rpc"
    [
      test "the snapshot is Absent without a watch" snapshot_absent;
      store_rules;
      watch_law;
      test "attach against a live dune watch" attach_live;
    ]
