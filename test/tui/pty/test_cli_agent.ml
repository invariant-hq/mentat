(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Tui_harness
open Cli_launch_fixture
module Pty = Pty_session

(* The TUI spawns and dials: opening a session starts the session's own agent
   (a [mentat serve] process on the session's derived socket), the prompt
   round-trips over that socket, and closing the TUI leaves the agent to idle
   out on its own — the TUI's connections were its only lease. The socket
   tree is the observation point: one leaf per served session, gone when its
   agent exits. *)

(* The per-user socket base for this project's hermetic data home, read from
   the binary itself so the test never re-derives the data-home digest. *)
let agent_socket_base project =
  let out = Project.scratch project "agent/dirs.out" in
  Project.write_path out "";
  let executable = Project.resolve_env_path "MENTAT_BIN" in
  let fd = Unix.openfile out [ Unix.O_CREAT; Unix.O_TRUNC; Unix.O_WRONLY ] 0o600 in
  let null = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
  let pid =
    Fun.protect
      ~finally:(fun () ->
        Unix.close fd;
        Unix.close null)
      (fun () ->
        Unix.create_process_env executable
          [| executable; "debug"; "dirs" |]
          (Project.env_array ~extra:[] ~unset:[] project)
          null fd fd)
  in
  ignore (waitpid_blocking pid : Unix.process_status);
  let contents = Project.read_path out in
  let sockets =
    List.find_map
      (fun line ->
        if String.length line > 8 && String.sub line 0 8 = "sockets=" then
          Some (String.sub line 8 (String.length line - 8))
        else None)
      (String.split_on_char '\n' contents)
  in
  match sockets with
  | Some base -> base
  | None -> failwith ("debug dirs printed no sockets line: " ^ contents)

let serving_leaves tree =
  match Sys.readdir tree with
  | entries -> Array.to_list entries
  | exception Sys_error _ -> []

let rec await_no_leaves tree limit =
  if serving_leaves tree = [] then true
  else if limit <= 0. then false
  else begin
    Unix.sleepf 0.1;
    await_no_leaves tree (limit -. 0.1)
  end

let%expect_test
    "a prompt starts the session's agent; closing the TUI lets it idle out" =
  let prompt = "drive through the agent" in
  let answer = "The turn ran in the session's own agent." in
  Project.with_temp "cli-agent-dial" @@ fun project ->
  with_provider project ~prompt ~answer @@ fun base_url ->
  let tree = Filename.concat (agent_socket_base project) "s" in
  require (serving_leaves tree = []) "no agent serves before the launch";
  Pty.run
    ~env:
      [
        ("OPENAI_API_KEY", "test-key");
        ("MENTAT_OPENAI_BASE_URL", base_url);
        ("MENTAT_CHILD_LINGER", "0.5");
      ]
    ~command:[ "--prompt"; prompt ]
    ~ready:(fun screen ->
      Screen.contains screen prompt
      && Screen.contains screen answer
      && Screen.contains screen "❯ message mentat")
    project
  @@ fun terminal ->
  (* The round-trip on screen proves the dial; the socket leaf proves the
     agent process is real and serving while the TUI holds the session. *)
  require
    (List.length (serving_leaves tree) = 1)
    "one agent serves the opened session";
  Pty.settle terminal;
  Screen.print ~project (Pty.screen terminal);
  [%expect
    {|
    01 |
    02 |  █▄█ ██▀ █▀▄ ▀█▀ ▄▀█ ▀█▀   ·    dev · openai/gpt-5.6-sol medium
    03 |  █ █ █▄▄ █ █  █  █▀█  █  ▂▄▆▄▂  ~/mentat-tui-cli-aga3c12c73
    04 |
    05 | ❯ drive through the agent
    06 |
    07 | ⏺ The turn ran in the session's own agent.
    08 |
    09 |
    10 |
    11 |
    12 |
    13 |
    14 |
    15 |
    16 |
    17 |
    18 |
    19 |
    20 |
    21 | ────────────────────────────────────────────────────────────────────────────────
    22 | ❯ message mentat
    23 | ────────────────────────────────────────────────────────────────────────────────
    24 |   ~/mentat-tui-cli-aga… · openai/gpt-5.6-sol med… · ! full access ? for short…
    |}];
  Pty.quit terminal;
  (* The TUI is gone; nothing holds a connection, so the settled agent idles
     out on its short linger and removes its endpoint. *)
  require
    (await_no_leaves tree 10.)
    "the agent idled out after the TUI closed"
