(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Ported from the Codex reference agent's seatbelt_base_policy.sbpl, itself
   derived from Chrome's macOS sandbox policy. Production-proven base
   allowances: process exec/fork, /dev/null, sysctls, PTYs, and read-only
   user preferences. *)
let base_policy =
  {|(version 1)

; start with closed-by-default
(deny default)

; child processes inherit the policy of their parent
(allow process-exec)
(allow process-fork)
(allow signal (target same-sandbox))

; process-info
(allow process-info* (target same-sandbox))

(allow file-write-data
  (require-all
    (path "/dev/null")
    (vnode-type CHARACTER-DEVICE)))

; inherited stdio is the host-owned process channel, not host-file authority
(allow file-read-data file-test-existence file-write-data
  (subpath "/dev/fd"))
(allow file-read* (regex #"^/dev/fd/(0|1|2)$"))
(allow file-write* (regex #"^/dev/fd/(1|2)$"))
(allow file-read-metadata
  (literal "/dev")
  (literal "/dev/stdin")
  (literal "/dev/stdout")
  (literal "/dev/stderr"))

; guarded vnodes and the sandbox-container query used by macOS runtimes
(allow system-mac-syscall (mac-policy-name "vnguard"))
(allow system-mac-syscall
  (require-all
    (mac-policy-name "Sandbox")
    (mac-syscall-number 67)))

; resolve standard symlinks and firmlink ancestors without granting their data
(allow file-read-metadata file-test-existence
  (literal "/etc")
  (literal "/tmp")
  (literal "/var")
  (literal "/private/etc/localtime"))
(allow file-read-metadata file-test-existence
  (path-ancestors "/System/Volumes/Data/private"))
(allow file-read* file-test-existence (literal "/"))
(allow system-fsctl (fsctl-command FSIOC_CAS_BSDFLAGS))

; standard non-secret device handles required by libc and language runtimes
(allow file-read* file-test-existence
  (literal "/dev/autofs_nowait")
  (literal "/dev/random")
  (literal "/dev/urandom"))
(allow file-read* file-test-existence file-write-data
  (literal "/dev/null")
  (literal "/dev/zero"))

; sysctls permitted.
(allow sysctl-read
  (sysctl-name "hw.activecpu")
  (sysctl-name "hw.busfrequency_compat")
  (sysctl-name "hw.byteorder")
  (sysctl-name "hw.cacheconfig")
  (sysctl-name "hw.cachelinesize_compat")
  (sysctl-name "hw.cpufamily")
  (sysctl-name "hw.cpufrequency_compat")
  (sysctl-name "hw.cputype")
  (sysctl-name "hw.l1dcachesize_compat")
  (sysctl-name "hw.l1icachesize_compat")
  (sysctl-name "hw.l2cachesize_compat")
  (sysctl-name "hw.l3cachesize_compat")
  (sysctl-name "hw.logicalcpu_max")
  (sysctl-name "hw.machine")
  (sysctl-name "hw.model")
  (sysctl-name "hw.memsize")
  (sysctl-name "hw.ncpu")
  (sysctl-name "hw.nperflevels")
  (sysctl-name-prefix "hw.optional.arm.")
  (sysctl-name-prefix "hw.optional.armv8_")
  (sysctl-name "hw.packages")
  (sysctl-name "hw.pagesize_compat")
  (sysctl-name "hw.pagesize")
  (sysctl-name "hw.physicalcpu")
  (sysctl-name "hw.physicalcpu_max")
  (sysctl-name "hw.logicalcpu")
  (sysctl-name "hw.cpufrequency")
  (sysctl-name "hw.tbfrequency_compat")
  (sysctl-name "hw.vectorunit")
  (sysctl-name "machdep.cpu.brand_string")
  (sysctl-name "kern.argmax")
  (sysctl-name "kern.hostname")
  (sysctl-name "kern.maxfilesperproc")
  (sysctl-name "kern.maxproc")
  (sysctl-name "kern.osproductversion")
  (sysctl-name "kern.osrelease")
  (sysctl-name "kern.ostype")
  (sysctl-name "kern.osvariant_status")
  (sysctl-name "kern.osversion")
  (sysctl-name "kern.secure_kernel")
  (sysctl-name "kern.usrstack64")
  (sysctl-name "kern.version")
  (sysctl-name "sysctl.proc_cputype")
  (sysctl-name "vm.loadavg")
  (sysctl-name-prefix "hw.perflevel")
  (sysctl-name-prefix "kern.proc.pgrp.")
  (sysctl-name-prefix "kern.proc.pid.")
  (sysctl-name-prefix "net.routetable.")
)

; Allow Java to read some CPU info. This is misclassified as a "write" because
; userspace passes a memory buffer to the sysctl, but conceptually it is a read.
(allow sysctl-write
  (sysctl-name "kern.grade_cputype"))

; IOKit
(allow iokit-open
  (iokit-registry-entry-class "RootDomainUserClient")
)

; needed to look up user info
(allow mach-lookup
  (global-name "com.apple.system.opendirectoryd.libinfo")
)

; Needed for python multiprocessing on MacOS for the SemLock
(allow ipc-posix-sem)

; Needed for PyTorch/libomp on macOS to register OpenMP runtimes.
(allow ipc-posix-shm-read-data
  ipc-posix-shm-write-create
  ipc-posix-shm-write-unlink
  (ipc-posix-name-regex #"^/__KMP_REGISTERED_LIB_[0-9]+$"))

(allow mach-lookup
  (global-name "com.apple.analyticsd")
  (global-name "com.apple.analyticsd.messagetracer")
  (global-name "com.apple.appsleep")
  (global-name "com.apple.bsd.dirhelper")
  (global-name "com.apple.diagnosticd")
  (global-name "com.apple.logd")
  (global-name "com.apple.logd.events")
  (global-name "com.apple.runningboard")
  (global-name "com.apple.secinitd")
  (global-name "com.apple.system.DirectoryService.libinfo_v1")
  (global-name "com.apple.system.logger")
  (global-name "com.apple.system.notification_center")
  (global-name "com.apple.system.opendirectoryd.membership")
  (global-name "com.apple.trustd")
  (global-name "com.apple.trustd.agent")
  (global-name "com.apple.xpc.activity.unmanaged")
  (global-name "com.apple.PowerManagement.control")
)

(allow network-outbound (literal "/private/var/run/syslog"))
(allow ipc-posix-shm-read*
  (ipc-posix-name "apple.shm.notification_center"))

; allow openpty()
(allow pseudo-tty)
(allow file-read* file-write* file-ioctl (literal "/dev/ptmx"))
(allow file-read* file-write*
  (require-all
    (regex #"^/dev/ttys[0-9]+")
    (extension "com.apple.sandbox.pty")))
; PTYs created before entering seatbelt may lack the extension; allow ioctl
; on those slave ttys so interactive shells detect a TTY and remain functional.
(allow file-ioctl (regex #"^/dev/ttys[0-9]+"))

; allow readonly user preferences
(allow ipc-posix-shm-read* (ipc-posix-name-prefix "apple.cfprefs."))
(allow mach-lookup
  (global-name "com.apple.cfprefsd.daemon")
  (global-name "com.apple.cfprefsd.agent")
  (local-name "com.apple.cfprefsd.agent"))
(allow user-preference-read)|}

(* The FSEvents session with fseventsd. A confined [dune build --watch] (and
   any other file watcher using the FSEvents framework) opens its event
   stream through this mach service; without the lookup the framework's
   [FSEventStreamStart] fails and dune aborts at startup with
   "Fsevents.start: failed to start". The service only delivers change
   notifications for paths — event payloads carry path names and flags, never
   file data — so the reads the policy denies stay denied. *)
let fsevents_policy =
  {|(allow mach-lookup (global-name "com.apple.FSEvents"))|}

(* Ported from the Codex reference agent's seatbelt_network_policy.sbpl:
   platform services TLS, DNS, and network configuration need beyond raw
   socket access when the policy enables network. *)
let network_policy =
  {|; allow only safe AF_SYSTEM sockets used for local platform services.
(allow system-socket
  (require-all
    (socket-domain AF_SYSTEM)
    (socket-protocol 2)
  )
)

(allow mach-lookup
    ; Used by platform helpers that resolve user directory locations.
    (global-name "com.apple.bsd.dirhelper")
    (global-name "com.apple.system.opendirectoryd.membership")

    ; Communicate with the security server for TLS certificate information.
    (global-name "com.apple.SecurityServer")
    (global-name "com.apple.networkd")
    (global-name "com.apple.ocspd")
    (global-name "com.apple.trustd.agent")

    ; Read network configuration.
    (global-name "com.apple.SystemConfiguration.DNSConfiguration")
    (global-name "com.apple.SystemConfiguration.configd")
)

(allow sysctl-read
  (sysctl-name-regex #"^net.routetable")
)|}

let clause_param index = Printf.sprintf "PATH_%d" index

(* One rule per clause, shallowest first. SBPL is last-match-wins, so emission
   order is the resolution law and a [Read] clause beneath a [Write] one simply
   overrides it — no [require-not] threading, and no rule has to know which
   other rule it is carving out of.

   Paths are [-D] parameters, never profile text. [file-map-executable] rides
   with read because a binary must be mappable to run, and [path-ancestors]
   grants metadata — never data — along each clause's parent chain, which
   [realpath] and ordinary path resolution walk. *)
let clause_rules params =
  List.map
    (fun (param, _, access) ->
      match access with
      | Policy.Access.Read ->
          (* The read allow does not revoke a shallower write allow: SBPL
             resolves per operation, so a rule that never mentions
             [file-write*] cannot override one that does. The explicit write
             deny is what makes a [Read] clause beneath a [Write] one act as a
             carveout, and it is harmless where nothing granted the write. *)
          Printf.sprintf
            "(allow file-read* file-test-existence file-map-executable\n\
             (literal (param \"%s\")) (subpath (param \"%s\")))\n\
             (deny file-write*\n\
             (subpath (param \"%s\")))"
            param param param
      | Policy.Access.Write ->
          Printf.sprintf
            "(allow file-read* file-test-existence file-map-executable\n\
             (literal (param \"%s\")) (subpath (param \"%s\")))\n\
             (allow file-write*\n\
             (subpath (param \"%s\")))"
            param param param
      | Policy.Access.Deny ->
          Printf.sprintf
            "(deny file-read* file-write* file-test-existence\n\
             (literal (param \"%s\")) (subpath (param \"%s\")))"
            param param)
    params

(* The root is skipped, and not as a tidy-up: [(path-ancestors "/")] does not
   compile — [sandbox-exec] rejects the profile with "argument expected but none
   provided" and exits 65 before the command runs. Root has no ancestors to
   name, and every path already reaches it, so dropping it costs nothing. *)
let ancestor_rule params =
  match
    List.filter
      (fun (_, path, access) ->
        (not (Policy.Access.equal access Policy.Access.Deny))
        && not (String.equal path (Lpath.Abs.to_string Lpath.Abs.root)))
      params
  with
  | [] -> ""
  | granted ->
      Printf.sprintf "(allow file-read-metadata file-test-existence\n%s\n)"
        (String.concat " "
           (List.map
              (fun (param, _, _) ->
                Printf.sprintf "(path-ancestors (param \"%s\"))" param)
              granted))

let default_read_rule policy =
  match Policy.reads_default policy with
  | Policy.All -> "(allow file-read*)\n(allow file-map-executable)"
  | Policy.Denied -> ""

(* Local build IPC — dune serves its RPC over a socket under the build
   directory — is governed by [network-bind]/[network-outbound] filtered by the
   socket's pathname, which an INET bind carries none of, so admitting it under
   the writable clauses opens no INET boundary. An allow with an empty predicate
   list is an allow with no filter, so a posture granting no writable path emits
   no rule at all. *)
let unix_socket_policy params =
  match
    List.filter
      (fun (_, _, access) -> Policy.Access.equal access Policy.Access.Write)
      params
  with
  | [] -> ""
  | writable ->
      Printf.sprintf "(allow network-bind network-outbound\n%s\n)"
        (String.concat " "
           (List.map
              (fun (param, _, _) ->
                Printf.sprintf "(subpath (param \"%s\"))" param)
              writable))

let network_section policy =
  match Policy.network policy with
  | Policy.Network.Restricted -> ""
  | Policy.Network.Enabled ->
      Printf.sprintf "(allow network-outbound)\n(allow network-inbound)\n%s"
        network_policy

(* The per-session launchd endpoints under [/private/tmp] — above all the
   ssh-agent socket [SSH_AUTH_SOCK] names — sit inside a directory every
   writable posture grants, so the Unix-socket allowance above reaches them
   and their glob is discoverable through the same grant. Stripping the
   variable from the child environment is therefore friction, not a boundary:
   the agent that signs for every host the user can reach is one readdir and
   one connect away. This denial closes the capability itself — the connect,
   and the reads that would discover the path — and it is emitted after every
   other section because SBPL resolves last-match-wins: not even an enabled
   network's blanket outbound allowance may re-open it. *)
let agent_socket_denial =
  {|(deny network-outbound network-bind file-read* file-write* file-test-existence
  (regex #"^/private/tmp/com\.apple\.launchd\."))|}

let sbpl policy =
  let params =
    List.mapi
      (fun index (path, access) ->
        (clause_param index, Lpath.Abs.to_string path, access))
      (Policy.entries policy)
  in
  let sections =
    List.filter
      (fun section -> not (String.equal section ""))
      ((base_policy :: default_read_rule policy :: clause_rules params)
      @ [
          ancestor_rule params;
          unix_socket_policy params;
          fsevents_policy;
          network_section policy;
          agent_socket_denial;
        ])
  in
  ( String.concat "\n" sections,
    List.map (fun (param, value, _) -> (param, value)) params )
