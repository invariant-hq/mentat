(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Unit suite for [Service], mentatd's resident-service surface — the pure
   half only: unit rendering, unit paths, and the standing of an existing
   file, driven with no filesystem or service manager behind them. The module
   lives in [bin/mentatd] and is not library-linkable, so its source is
   copied into this test executable by the [copy_files] rule in [dune]. *)

open Windtrap

let exec = "/usr/local/bin/mentatd"
let log = "/home/owner/.local/share/mentat/daemon/daemon.log"

let rendered ?(args = []) platform ~exec ~log =
  match Service.Unit_file.render platform ~exec ~args ~log with
  | Ok rendered -> rendered
  | Error message -> failf "render refused: %s" message

let refused ?(args = []) platform ~exec ~log =
  match Service.Unit_file.render platform ~exec ~args ~log with
  | Ok _ -> fail "render accepted a value it must refuse"
  | Error message -> message

(* The two renders are pinned byte-for-byte: the unit file is an outward
   contract (a service manager parses it, an owner reads it), so any drift is
   a deliberate golden edit here. *)

let launchd_golden =
  {|<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- Written by `mentatd install`; `mentatd uninstall` removes it, and the
     next install overwrites it. AbandonProcessGroup is load-bearing: the
     daemon's run children detach into their own sessions and must outlive
     it, so stopping or restarting this job may signal only the daemon
     itself — it adopts the survivors when it next boots. Without the key,
     launchd would take mid-turn runs down with the job. -->
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.invarianthq.mentatd</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/mentatd</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>AbandonProcessGroup</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/home/owner/.local/share/mentat/daemon/daemon.log</string>
  <key>StandardErrorPath</key>
  <string>/home/owner/.local/share/mentat/daemon/daemon.log</string>
</dict>
</plist>
|}

let systemd_golden =
  {|# Written by `mentatd install`; `mentatd uninstall` removes it, and the
# next install overwrites it. KillMode=process is load-bearing: the daemon's
# run children detach into their own sessions and must outlive it, so
# stopping or restarting this unit may signal only the daemon itself — it
# adopts the survivors when it next boots. The default control-group kill
# would take mid-turn runs down with the unit. The restart pacing is
# load-bearing too: a daemon spawned outside the service holds the per-user
# claim and this unit's daemon then exits nonzero, so the manager must retry
# until the claim frees — the default burst limit would park the unit failed
# after five fast exits instead.

[Unit]
Description=mentat daemon
StartLimitIntervalSec=0

[Service]
ExecStart="/usr/local/bin/mentatd"
KillMode=process
Restart=on-failure
RestartSec=10
StandardOutput=append:/home/owner/.local/share/mentat/daemon/daemon.log
StandardError=append:/home/owner/.local/share/mentat/daemon/daemon.log

[Install]
WantedBy=default.target
|}

let renders =
  group "rendering"
    [
      test "the launchd unit, byte for byte" (fun () ->
          let unit = rendered Service.Platform.Macos ~exec ~log in
          equal string launchd_golden unit;
          (* The child-survival pin, asserted on its own: the one line the
             whole crash story depends on. *)
          contains ~sub:"<key>AbandonProcessGroup</key>\n  <true/>" unit);
      test "the systemd unit, byte for byte" (fun () ->
          let unit = rendered Service.Platform.Linux ~exec ~log in
          equal string systemd_golden unit;
          contains ~sub:"\nKillMode=process\n" unit;
          (* The claim-held retry contract: the manager must retry until a
             spawned daemon frees the claim, paced, never parked failed by
             the default burst limit. *)
          contains ~sub:"\nStartLimitIntervalSec=0\n" unit;
          contains ~sub:"\nRestartSec=10\n" unit);
      test "both renders carry the ownership marker" (fun () ->
          is_true
            (Service.Unit_file.ours (rendered Service.Platform.Macos ~exec ~log));
          is_true
            (Service.Unit_file.ours (rendered Service.Platform.Linux ~exec ~log)));
      test "XML metacharacters in a launchd path are escaped" (fun () ->
          let unit =
            rendered Service.Platform.Macos ~exec:"/tmp/a&b<c>/mentatd" ~log
          in
          contains ~sub:"<string>/tmp/a&amp;b&lt;c&gt;/mentatd</string>" unit;
          not_contains ~sub:"<string>/tmp/a&b" unit);
      test "a percent under systemd is doubled" (fun () ->
          let unit =
            rendered Service.Platform.Linux ~exec ~log:"/var/log/100%/d.log"
          in
          contains ~sub:"StandardOutput=append:/var/log/100%%/d.log" unit);
      test "a control character is refused on both platforms" (fun () ->
          let exec = "/tmp/evil\nmentatd" in
          contains ~sub:"control character"
            (refused Service.Platform.Macos ~exec ~log);
          contains ~sub:"control character"
            (refused Service.Platform.Linux ~exec ~log));
      test "a quote or backslash is refused under systemd only" (fun () ->
          let exec = {|/tmp/we"ird/mentatd|} in
          contains ~sub:"quote, backslash, or dollar sign"
            (refused Service.Platform.Linux ~exec ~log);
          contains ~sub:{|<string>/tmp/we"ird/mentatd</string>|}
            (rendered Service.Platform.Macos ~exec ~log));
      test "install flags ride the exec line on both platforms" (fun () ->
          let args =
            [
              "--ingress-port=8080";
              "--github-base-url=https://ghe.example.test/api/v3";
              "--routine-git-base=https://ghe.example.test";
              "--web";
              "--web-port=8081";
            ]
          in
          let plist = rendered ~args Service.Platform.Macos ~exec ~log in
          contains
            ~sub:
              "    <string>/usr/local/bin/mentatd</string>\n\
              \    <string>--ingress-port=8080</string>\n\
              \    <string>--github-base-url=https://ghe.example.test/api/v3</string>\n\
              \    <string>--routine-git-base=https://ghe.example.test</string>\n\
              \    <string>--web</string>\n\
              \    <string>--web-port=8081</string>"
            plist;
          let unit = rendered ~args Service.Platform.Linux ~exec ~log in
          contains
            ~sub:
              "ExecStart=\"/usr/local/bin/mentatd\" \"--ingress-port=8080\" \
               \"--github-base-url=https://ghe.example.test/api/v3\" \
               \"--routine-git-base=https://ghe.example.test\" \"--web\" \
               \"--web-port=8081\"\n"
            unit);
      test "arguments walk the same refusals as paths" (fun () ->
          let args = [ "--github-base-url=https://x/\ny" ] in
          contains ~sub:"control character"
            (refused ~args Service.Platform.Macos ~exec ~log);
          contains ~sub:"control character"
            (refused ~args Service.Platform.Linux ~exec ~log);
          let quoted = [ {|--github-base-url=https://x/"y|} ] in
          contains ~sub:"quote, backslash, or dollar sign"
            (refused ~args:quoted Service.Platform.Linux ~exec ~log);
          contains ~sub:{|<string>--github-base-url=https://x/"y</string>|}
            (rendered ~args:quoted Service.Platform.Macos ~exec ~log);
          (* systemd substitutes $VAR even inside double quotes, silently
             rewriting the value, so a dollar sign is refused rather than
             guessed at; launchd carries it literally. *)
          let dollar = [ "--github-base-url=https://x/api/${TENANT}" ] in
          contains ~sub:"quote, backslash, or dollar sign"
            (refused ~args:dollar Service.Platform.Linux ~exec ~log);
          contains
            ~sub:"<string>--github-base-url=https://x/api/${TENANT}</string>"
            (rendered ~args:dollar Service.Platform.Macos ~exec ~log);
          let percent = [ "--github-base-url=https://x/a%20b" ] in
          contains ~sub:"\"--github-base-url=https://x/a%%20b\""
            (rendered ~args:percent Service.Platform.Linux ~exec ~log));
    ]

let paths =
  group "unit paths"
    [
      test "macOS: the LaunchAgents plist under home" (fun () ->
          equal string
            "/Users/owner/Library/LaunchAgents/dev.invarianthq.mentatd.plist"
            (Service.Unit_file.path Service.Platform.Macos ~home:"/Users/owner"
               ~xdg_config_home:(Some "/Users/owner/xdg")));
      test "Linux: ~/.config without an XDG override" (fun () ->
          equal string "/home/owner/.config/systemd/user/mentatd.service"
            (Service.Unit_file.path Service.Platform.Linux ~home:"/home/owner"
               ~xdg_config_home:None));
      test "Linux: an absolute XDG_CONFIG_HOME wins" (fun () ->
          equal string "/somewhere/else/systemd/user/mentatd.service"
            (Service.Unit_file.path Service.Platform.Linux ~home:"/home/owner"
               ~xdg_config_home:(Some "/somewhere/else")));
      test "Linux: a relative XDG_CONFIG_HOME is ignored" (fun () ->
          equal string "/home/owner/.config/systemd/user/mentatd.service"
            (Service.Unit_file.path Service.Platform.Linux ~home:"/home/owner"
               ~xdg_config_home:(Some "relative/config")));
    ]

let standing_of existing =
  Service.Unit_file.standing ~existing
    ~rendered:(rendered Service.Platform.Linux ~exec ~log)

let standing =
  let testable =
    Testable.make
      ~pp:(fun ppf -> function
        | Service.Unit_file.Fresh -> Format.pp_print_string ppf "Fresh"
        | Service.Unit_file.Unchanged -> Format.pp_print_string ppf "Unchanged"
        | Service.Unit_file.Replaceable ->
            Format.pp_print_string ppf "Replaceable"
        | Service.Unit_file.Foreign -> Format.pp_print_string ppf "Foreign")
      ~equal:(fun (a : Service.Unit_file.standing) b -> a = b)
  in
  group "standing"
    [
      test "an absent file is fresh" (fun () ->
          equal testable Service.Unit_file.Fresh (standing_of None));
      test "identical bytes are unchanged" (fun () ->
          equal testable Service.Unit_file.Unchanged
            (standing_of (Some (rendered Service.Platform.Linux ~exec ~log))));
      test "our marker with different bytes is replaceable" (fun () ->
          equal testable Service.Unit_file.Replaceable
            (standing_of
               (Some
                  (rendered Service.Platform.Linux ~exec:"/old/mentatd" ~log))));
      test "anything else is foreign" (fun () ->
          equal testable Service.Unit_file.Foreign
            (standing_of (Some "[Service]\nExecStart=/usr/bin/other\n")));
    ]

let () = run "mentatd.service" [ renders; paths; standing ]
