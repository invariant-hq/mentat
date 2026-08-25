(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Unit suite for [mentat_sandbox], the pure half of the command-confinement
   subsystem. The suite pins this library's security-boundary
   contracts: the pure golden generators (Seatbelt SBPL and Bubblewrap argv,
   asserted through [lower_argv] — the generators are library-internal), the
   fail-closed route constructors, the scratch-invariant confinement identity,
   the startup gate, and the obligation vocabulary the effect twin discharges.

   Everything here is a pure function of its inputs — no filesystem, no probe,
   no platform dependency — so a macOS profile golden verifies on Linux CI and
   back. Enforcement is injected as a required [(Backend.t, Error.t) result]
   {e selector}, never a caller-built profile, so a profile lowered from a
   different policy — and a forgotten probe outcome — are
   unrepresentable; the type system makes those tests unnecessary and we
   document them as such rather than forcing vacuous cases. *)

open Windtrap
module Sandbox = Mentat_sandbox
module Policy = Mentat_sandbox.Policy
module Evidence = Mentat_sandbox.Evidence
module Error = Mentat_sandbox.Error
module Backend = Mentat_sandbox.Backend
module Requirement = Mentat_sandbox.Requirement
module Identity = Mentat_sandbox.Identity
module Abs = Lpath.Abs
module Digest = Mentat_digest
module Json = Jsont.Json

(* Helpers *)

let abs path = Abs.of_string_exn path
let abs_value = Testable.make ~pp:Abs.pp ~equal:Abs.equal
let policy_value = Testable.make ~pp:Policy.pp ~equal:Policy.equal
let evidence_value = Testable.make ~pp:Evidence.pp ~equal:Evidence.equal
let error_value = Testable.make ~pp:Error.pp ~equal:Error.equal
let json_string s = Json.string s

(* The suites still speak in root lists; this projects them onto clauses so the
   tests describe a posture rather than an emission order. *)
let confined ?reads ?(writable_roots = []) ?(protected_paths = [])
    ?(denied_paths = []) ?(network = Policy.Network.Restricted) () =
  let reads_default, read_roots =
    match reads with
    | None -> (Policy.All, [])
    | Some roots -> (Policy.Denied, roots)
  in
  let clause access = List.map (fun p -> (p, access)) in
  let entries =
    clause Policy.Access.Read read_roots
    @ clause Policy.Access.Write writable_roots
    @ clause Policy.Access.Read protected_paths
    @ clause Policy.Access.Deny denied_paths
  in
  Policy.make ~entries ~reads_default ~network

let sealed ?(backend = Backend.Seatbelt) ?(mutates = true) policy =
  Sandbox.confined ~backend:(Ok backend) ~mutates policy

let refused_sealed ?(error = Error.Unavailable "no backend") policy =
  Sandbox.confined ~backend:(Error error) ~mutates:true policy

let identity_of ?backend policy = Sandbox.identity (sealed ?backend policy)

let lowered ?cwd sandbox ~program args =
  let cwd = match cwd with Some cwd -> cwd | None -> abs "/tmp" in
  match Sandbox.lower_argv sandbox ~cwd (program :: args) with
  | Ok tokens -> tokens
  | Error error -> fail (Error.message error)

(* Any admitted read root serves; lowering re-checks lexical containment. *)
let cwd_in_scope policy =
  match (Policy.reads_default policy, Policy.readable_roots policy) with
  | Policy.All, _ -> abs "/tmp"
  | Policy.Denied, root :: _ -> root
  | Policy.Denied, [] -> abs "/tmp"

(* The generators are library-internal; the golden surface is the lowered
   argv. For Seatbelt the SBPL document is the argv token after
   ["-p"] and each following ["-DKEY=VALUE"] token carries one (key, path)
   parameter; for Bubblewrap the enforcing prefix is the argv verbatim.
   [seatbelt_sbpl] lowers a probe command with a cwd inside the read scope and
   projects the (sbpl, params) pair back out of the argv. *)
let seatbelt_sbpl policy =
  let tokens =
    lowered
      (sealed ~backend:Backend.Seatbelt policy)
      ~cwd:(cwd_in_scope policy) ~program:"cmd" []
  in
  match tokens with
  | "/usr/bin/sandbox-exec" :: "-p" :: sbpl :: rest ->
      let param token =
        match String.index_opt token '=' with
        | Some i when String.starts_with ~prefix:"-D" token ->
            ( String.sub token 2 (i - 2),
              String.sub token (i + 1) (String.length token - i - 1) )
        | _ -> failf "malformed -D parameter: %s" token
      in
      let rec params acc = function
        | [ "--"; "cmd" ] -> List.rev acc
        | token :: rest -> params (param token :: acc) rest
        | [] -> fail "seatbelt lowering lost the -- command tail"
      in
      (sbpl, params [] rest)
  | _ -> fail "seatbelt lowering must start with the executable and -p profile"

let bubblewrap_lowered ?cwd policy ~program args =
  lowered (sealed ~backend:Backend.Bubblewrap policy) ?cwd ~program args

(* Error. *)

let error_constructors_are_distinct () =
  let cases =
    [
      Error.Unavailable "x";
      Error.Cwd_outside_scope (abs "/x");
      Error.Escalation_denied;
      Error.Escalation_irrelevant;
      Error.Empty_program;
      Error.Nul_in_argv { index = 1 };
      Error.Stale_policy { path = abs "/x" };
    ]
  in
  List.iteri
    (fun i a ->
      List.iteri
        (fun j b ->
          if i = j then is_true ~msg:"an error equals itself" (Error.equal a b)
          else
            is_false ~msg:"distinct constructors are unequal" (Error.equal a b))
        cases)
    cases;
  is_false ~msg:"fields participate in equality"
    (Error.equal (Error.Unavailable "a") (Error.Unavailable "b"));
  is_false ~msg:"paths participate in equality"
    (Error.equal
       (Error.Stale_policy { path = abs "/a" })
       (Error.Stale_policy { path = abs "/b" }))

let error_messages_carry_fields () =
  equal string ~msg:"unavailable message is the probe diagnostic" "gone"
    (Error.message (Error.Unavailable "gone"));
  equal string ~msg:"cwd_outside_scope names the cwd"
    "working directory /elsewhere is outside the confined readable roots"
    (Error.message (Error.Cwd_outside_scope (abs "/elsewhere")));
  equal string ~msg:"stale_policy names the exact path"
    "resolved sandbox path /work/.git disappeared or changed kind after sealing"
    (Error.message (Error.Stale_policy { path = abs "/work/.git" }));
  equal string ~msg:"nul_in_argv names the token index"
    "argv token 1 contains a NUL byte"
    (Error.message (Error.Nul_in_argv { index = 1 }));
  equal string ~msg:"pp renders the message"
    (Error.message Error.Empty_program)
    (Format.asprintf "%a" Error.pp Error.Empty_program)

let error_json_shape () =
  let obj fields =
    Json.object'
      (List.map (fun (name, value) -> Json.mem (Json.name name) value) fields)
  in
  is_true ~msg:"unavailable json is kind and message"
    (Json.equal
       (obj
          [
            ("kind", json_string "unavailable"); ("message", json_string "gone");
          ])
       (Error.to_json (Error.Unavailable "gone")));
  is_true ~msg:"cwd_outside_scope json carries the structured path"
    (Json.equal
       (obj
          [
            ("kind", json_string "cwd_outside_scope");
            ( "message",
              json_string
                "working directory /elsewhere is outside the confined readable \
                 roots" );
            ("path", json_string "/elsewhere");
          ])
       (Error.to_json (Error.Cwd_outside_scope (abs "/elsewhere"))));
  is_true ~msg:"stale_policy json carries the structured path"
    (Json.equal
       (obj
          [
            ("kind", json_string "stale_policy");
            ( "message",
              json_string
                "resolved sandbox path /work/.git disappeared or changed kind \
                 after sealing" );
            ("path", json_string "/work/.git");
          ])
       (Error.to_json (Error.Stale_policy { path = abs "/work/.git" })));
  is_true ~msg:"nul_in_argv json carries the structured index"
    (Json.equal
       (obj
          [
            ("kind", json_string "nul_in_argv");
            ("message", json_string "argv token 1 contains a NUL byte");
            ("index", Json.int 1);
          ])
       (Error.to_json (Error.Nul_in_argv { index = 1 })));
  is_true ~msg:"escalation_denied json is kind and message"
    (Json.equal
       (obj
          [
            ("kind", json_string "escalation_denied");
            ("message", json_string (Error.message Error.Escalation_denied));
          ])
       (Error.to_json Error.Escalation_denied))

let policy_distinguishes_network () =
  let restricted = confined () in
  let enabled = confined ~network:Policy.Network.Enabled () in
  is_false ~msg:"network state participates in equality"
    (Policy.equal restricted enabled);
  is_true ~msg:"default is restricted"
    (match Policy.network restricted with
    | Policy.Network.Restricted -> true
    | Policy.Network.Enabled -> false)

(* Descendants are not collapsed — the ordered model needs them, since a
   deeper clause is how a carveout overrides the root that contains it. What
   collapses is two clauses on one path, to the stronger. *)
let policy_collapses_only_duplicate_paths () =
  let policy =
    confined
      ~writable_roots:[ abs "/work"; abs "/work/sub" ]
      ~denied_paths:[ abs "/work/sub" ]
      ()
  in
  equal (list abs_value)
    ~msg:"a nested writable root survives as its own clause"
    [ abs "/work" ]
    (Policy.writable_roots policy);
  equal (list abs_value) ~msg:"the stronger access wins the duplicated path"
    [ abs "/work/sub" ]
    (Policy.denied_paths policy)

(* Nothing is discarded: a clause is meaningful wherever it lies. A membership
   filter that dropped a carveout outside every writable root would make the
   deny set impossible to express as one. *)
let policy_keeps_every_clause () =
  let policy =
    confined
      ~writable_roots:[ abs "/private/tmp"; abs "/private/tmp/ws" ]
      ~protected_paths:[ abs "/outside/.mentat"; abs "/private/tmp/ws/.mentat" ]
      ()
  in
  is_true ~msg:"a carveout outside every writable root survives"
    (List.exists
       (fun (path, access) ->
         Abs.equal path (abs "/outside/.mentat")
         && Policy.Access.equal access Policy.Access.Read)
       (Policy.entries policy));
  (* Both positions are asserted present before they are compared. The [-1]-on-
     miss spelling this replaces passed vacuously in the case that matters: when
     the *root* is the entry that vanished, [3 > -1] holds and the assertion
     claims an ordering between an entry and one that was never emitted. *)
  let position p =
    let rec find i = function
      | [] -> None
      | (path, _) :: _ when Abs.equal path (abs p) -> Some i
      | _ :: rest -> find (i + 1) rest
    in
    find 0 (Policy.entries policy)
  in
  let root =
    require_some ~msg:"the containing root is emitted"
      (position "/private/tmp/ws")
  in
  let nested =
    require_some ~msg:"the nested carveout is emitted"
      (position "/private/tmp/ws/.mentat")
  in
  satisfies int
    ~claim:"a nested carveout is emitted after the root that contains it"
    (fun nested -> nested > root)
    nested

let policy_folds_writable_into_reads () =
  let policy =
    confined ~reads:[ abs "/data" ] ~writable_roots:[ abs "/work" ] ()
  in
  equal (list abs_value)
    ~msg:"Only reads include the read roots and the writable roots"
    [ abs "/data"; abs "/work" ]
    (Policy.readable_roots policy)

let policy_denials_participate_in_equality () =
  is_false ~msg:"policies differing only by a denied path are unequal"
    (Policy.equal
       (confined ~denied_paths:[ abs "/a" ] ())
       (confined ~denied_paths:[ abs "/b" ] ()))

(* Generated antichain/coverage law for [Policy.make]'s root normalization
   (RFC L9). The result is strictly sorted, contains no root strictly within
   another (an antichain), and every input root is covered by some result
   root. *)

let path_component = Gen.of_list [ "a"; "b"; "c"; "d" ]

let abs_path_gen =
  Gen.map
    (fun components -> abs ("/" ^ String.concat "/" components))
    (Gen.list ~size:(Gen.int_range 1 4) path_component)

let root_list_gen = Gen.list (Gen.with_pp Abs.pp abs_path_gen)

(* The property the ordered model upholds: clauses come out shallowest-first,
   so the deepest clause naming a path is the last one emitted and therefore the
   one both backends resolve to. *)
let policy_entries_are_ordered_shallowest_first () =
  prop "entries are emitted shallowest-first" root_list_gen (fun roots ->
      let entries =
        Policy.entries
          (Policy.make
             ~entries:(List.map (fun r -> (r, Policy.Access.Read)) roots)
             ~reads_default:Policy.Denied ~network:Policy.Network.Restricted)
      in
      let depth p =
        String.fold_left
          (fun n c -> if Char.equal c '/' then n + 1 else n)
          0 (Abs.to_string p)
      in
      let rec ordered = function
        | (a, _) :: ((b, _) :: _ as rest) ->
            is_false ~msg:"a deeper clause never precedes a shallower one"
              (depth a > depth b);
            ordered rest
        | _ -> ()
      in
      ordered entries)

(* The root spelling makes a grant a different thing than it claims to be:
   the escalation wearing the narrow move's name. Refused naming itself. *)
let a_root_grant_is_refused () =
  let policy =
    Policy.make ~entries:[] ~reads_default:Policy.Denied
      ~network:Policy.Network.Restricted
  in
  match Policy.grant policy [ (Abs.root, Policy.Access.Read) ] with
  | Error (path, defeated) ->
      equal (list string) ~msg:"the root grant is refused naming itself"
        [ "/"; "/" ]
        [ Abs.to_string path; Abs.to_string defeated ]
  | Ok _ -> is_true ~msg:"the root grant is refused" false

let backend_identity () =
  equal string ~msg:"seatbelt id" "macos-seatbelt" (Backend.id Backend.Seatbelt);
  equal string ~msg:"bubblewrap id" "linux-bubblewrap"
    (Backend.id Backend.Bubblewrap);
  equal (list string) ~msg:"all backends in stable order"
    [ "macos-seatbelt"; "linux-bubblewrap" ]
    (List.map Backend.id Backend.all)

let backend_of_id_round_trips () =
  List.iter
    (fun backend ->
      is_true ~msg:"of_id inverts id"
        (match Backend.of_id (Backend.id backend) with
        | Some decoded -> Backend.equal backend decoded
        | None -> false))
    Backend.all;
  is_true ~msg:"unknown id is None" (Backend.of_id "windows-appcontainer" = None)

let backend_executables_are_fixed_and_absolute () =
  (* Hardening #3: fixed absolute enforcing executables; PATH cannot inject. *)
  equal string ~msg:"absolute sandbox-exec path" "/usr/bin/sandbox-exec"
    (Backend.executable Backend.Seatbelt);
  equal string ~msg:"absolute bwrap path" "/usr/bin/bwrap"
    (Backend.executable Backend.Bubblewrap)

let requirement_round_trips () =
  List.iter
    (fun r ->
      is_true ~msg:"of_string inverts to_string"
        (Requirement.of_string (Requirement.to_string r) = Some r))
    Requirement.all;
  equal (list string) ~msg:"configuration spellings"
    [ "off"; "enforced-or-external"; "enforced" ]
    (List.map Requirement.to_string Requirement.all);
  is_true ~msg:"unknown spelling is None" (Requirement.of_string "loose" = None)

let network_round_trips () =
  List.iter
    (fun n ->
      is_true ~msg:"of_string inverts to_string"
        (Policy.Network.of_string (Policy.Network.to_string n) = Some n))
    Policy.Network.all;
  is_true ~msg:"unknown spelling is None" (Policy.Network.of_string "vpn" = None)

(* Seatbelt SBPL generation (golden surface, through lower_argv). *)

(* Exact variable sections. The fixed base policy is a platform-independent
   constant; the read/write/network sections are what a policy generates, and
   each appears verbatim in the joined SBPL text. Pinning the full section
   string (not a loose fragment) is the exact-text golden. *)

let all_read_section = {|(allow file-read*)
(allow file-map-executable)|}

let seatbelt_read_only_golden () =
  let text, params = seatbelt_sbpl (confined ()) in
  contains ~msg:"profile starts closed-by-default" ~sub:"(deny default)" text;
  contains ~msg:"host-wide reads section is exact" ~sub:all_read_section text;
  (* A posture that grants no writable root emits no write section and no
     socket section. The socket guard is the load-bearing half: an allow with
     an empty predicate list is an unconditional allow, so emitting one here
     would hand every command full outbound under a restricted network. *)
  not_contains ~msg:"no writable root, so no write section"
    ~sub:"WRITABLE_ROOT_0" text;
  not_contains ~msg:"no writable root, so no unfiltered socket allow"
    ~sub:"(allow network-bind network-outbound" text;
  equal (list (pair string string)) ~msg:"no roots, no parameters" [] params;
  not_contains
    ~msg:"restricted network opens no INET boundary (no blanket outbound rule)"
    ~sub:"(allow network-outbound)" text;
  (* Every posture carries the FSEvents session: without it a confined
     [dune build --watch] aborts at startup because its file watcher cannot
     open the fseventsd stream. *)
  contains ~msg:"FSEvents mach service is admitted"
    ~sub:{|(allow mach-lookup (global-name "com.apple.FSEvents"))|} text

(* The profile is one rule per clause in emission order, so what these pin is
   the resolution law rather than a layout: the clause that decides a path is
   the last one naming it. *)
let seatbelt_scoped_reads_golden () =
  let policy =
    confined
      ~reads:[ abs "/opt/ocaml" ]
      ~writable_roots:[ abs "/work" ]
      ~protected_paths:[ abs "/work/.git" ]
      ()
  in
  let text, params = seatbelt_sbpl policy in
  not_contains ~msg:"scoped reads drop the host-wide read rule"
    ~sub:"(allow file-read*)" text;
  equal
    (list (pair string string))
    ~msg:"every clause is a parameter, shallowest first"
    [ ("PATH_0", "/work"); ("PATH_1", "/opt/ocaml"); ("PATH_2", "/work/.git") ]
    params;
  contains ~msg:"the writable clause grants writes"
    ~sub:"(allow file-write*\n(subpath (param \"PATH_0\")))" text;
  in_order
    ~msg:"the carveout's deny follows the grant it overrides, so it decides"
    ~subs:
      [
        "(allow file-write*\n(subpath (param \"PATH_0\")))";
        "(deny file-write*\n(subpath (param \"PATH_2\")))";
      ]
    text;
  is_true
    ~msg:"local Unix-socket IPC is admitted under the writable clause only"
    (String.includes
       ~affix:
         "(allow network-bind network-outbound\n(subpath (param \"PATH_0\"))\n)"
       text);
  not_contains
    ~msg:"restricted network opens no INET boundary (no blanket outbound rule)"
    ~sub:"(allow network-outbound)" text

let seatbelt_carveout_golden () =
  let policy =
    confined
      ~writable_roots:[ abs "/usr"; abs "/tmp" ]
      ~protected_paths:[ abs "/usr/bin"; abs "/usr/lib"; abs "/usr/share" ]
      ()
  in
  let text, params = seatbelt_sbpl policy in
  equal
    (list (pair string string))
    ~msg:"roots precede the carveouts beneath them"
    [
      ("PATH_0", "/tmp");
      ("PATH_1", "/usr");
      ("PATH_2", "/usr/bin");
      ("PATH_3", "/usr/lib");
      ("PATH_4", "/usr/share");
    ]
    params;
  List.iter
    (fun param ->
      is_true
        ~msg:("the carveout " ^ param ^ " denies writes")
        (String.includes
           ~affix:("(deny file-write*\n(subpath (param \"" ^ param ^ "\")))")
           text);
      contains
        ~msg:("the carveout " ^ param ^ " still reads")
        ~sub:("(subpath (param \"" ^ param ^ "\")))")
        text)
    [ "PATH_2"; "PATH_3"; "PATH_4" ]

let seatbelt_nested_roots_share_carveouts () =
  (* A workspace nested under another writable root must not have its protected
     metadata reachable through the enclosing root. Depth ordering is what
     guarantees it: the carveout is deeper than both roots, so it is emitted
     last and decides. *)
  let policy =
    confined
      ~writable_roots:[ abs "/private/tmp"; abs "/private/tmp/ws" ]
      ~protected_paths:[ abs "/private/tmp/ws/.git" ]
      ()
  in
  let text, params = seatbelt_sbpl policy in
  let param_of value =
    List.find_map
      (fun (k, v) -> if String.equal v value then Some k else None)
      params
  in
  match (param_of "/private/tmp/ws/.git", param_of "/private/tmp") with
  | Some carveout, Some enclosing ->
      in_order ~msg:"the enclosing root's write grant precedes the carveout"
        ~subs:
          [
            "(allow file-write*\n(subpath (param \"" ^ enclosing ^ "\")))";
            "(deny file-write*\n(subpath (param \"" ^ carveout ^ "\")))";
          ]
        text
  | _ -> fail "both the enclosing root and its carveout must be parameters"

let seatbelt_network_enabled_golden () =
  let text, _ = seatbelt_sbpl (confined ~network:Policy.Network.Enabled ()) in
  contains ~msg:"enabled network allows outbound"
    ~sub:"(allow network-outbound)" text;
  contains ~msg:"enabled network admits inbound" ~sub:"(allow network-inbound)"
    text;
  contains ~msg:"enabled network admits the TLS platform services"
    ~sub:"com.apple.SecurityServer" text

let seatbelt_no_path_enters_the_text () =
  (* Hardening #1: no path byte enters the SBPL text; every resolved path is a
     [-D] parameter. Distinctive paths never present in the fixed base policy
     make the property observable. *)
  let paths = [ "/data/secret"; "/work/project"; "/work/project/.git" ] in
  let policy =
    confined
      ~reads:[ abs "/data/secret" ]
      ~writable_roots:[ abs "/work/project" ]
      ~protected_paths:[ abs "/work/project/.git" ]
      ()
  in
  let text, params = seatbelt_sbpl policy in
  let values = List.map snd params in
  List.iter
    (fun path ->
      not_contains
        ~msg:(Printf.sprintf "no path %s appears in the SBPL text" path)
        ~sub:path text;
      is_true
        ~msg:(Printf.sprintf "path %s travels as a -D parameter" path)
        (List.mem path values))
    paths

let seatbelt_agent_socket_denied_last () =
  (* Stripping SSH_AUTH_SOCK from the child environment is friction, not a
     boundary: the launchd endpoint directory lives under /private/tmp, which
     every writable posture grants, and its name is one glob away. The profile
     denies the capability itself, and the denial must be the last word — an
     enabled network's blanket outbound allowance is emitted before it, and
     SBPL resolves last-match-wins. *)
  let denial = {|(regex #"^/private/tmp/com\.apple\.launchd\.")|} in
  let restricted, _ =
    seatbelt_sbpl (confined ~writable_roots:[ abs "/private/tmp" ] ())
  in
  contains ~msg:"a restricted posture denies the launchd endpoints" ~sub:denial
    restricted;
  in_order
    ~msg:"the denial follows the writable socket allowance, so it decides"
    ~subs:[ "(allow network-bind network-outbound"; denial ]
    restricted;
  let enabled, _ =
    seatbelt_sbpl (confined ~network:Policy.Network.Enabled ())
  in
  in_order
    ~msg:
      "an enabled network's blanket outbound precedes the denial, so the agent \
       socket stays closed"
    ~subs:[ "(allow network-outbound)"; denial ]
    enabled

let seatbelt_generation_is_deterministic () =
  let policy =
    confined
      ~writable_roots:[ abs "/usr"; abs "/tmp" ]
      ~protected_paths:[ abs "/usr/bin" ]
      ()
  in
  is_true ~msg:"equal policies produce byte-equal text and params"
    (seatbelt_sbpl policy = seatbelt_sbpl policy)

(* Bubblewrap argv generation (golden surface, through lower_argv). *)

let namespace_prefix =
  [
    "/usr/bin/bwrap";
    "--new-session";
    "--die-with-parent";
    "--unshare-user";
    "--unshare-pid";
  ]

let bubblewrap_read_only_golden () =
  equal (list string) ~msg:"read-only bubblewrap lowering is exact"
    (namespace_prefix
    @ [
        "--ro-bind";
        "/";
        "/";
        "--dev";
        "/dev";
        "--proc";
        "/proc";
        "--unshare-net";
        "--chdir";
        "/tmp";
        "--";
        "true";
      ])
    (bubblewrap_lowered (confined ()) ~cwd:(abs "/tmp") ~program:"true" [])

let bubblewrap_scoped_reads_golden () =
  let policy =
    confined
      ~reads:[ abs "/usr" ]
      ~writable_roots:[ abs "/usr" ]
      ~protected_paths:[ abs "/usr/bin" ]
      ()
  in
  let args = bubblewrap_lowered policy ~cwd:(abs "/usr") ~program:"true" [] in
  equal (list string) ~msg:"scoped-read bubblewrap lowering is exact"
    (namespace_prefix
    @ [
        "--tmpfs";
        "/";
        "--dev";
        "/dev";
        "--proc";
        "/proc";
        "--bind";
        "/usr";
        "/usr";
        "--ro-bind";
        "/usr/bin";
        "/usr/bin";
        "--unshare-net";
        "--remount-ro";
        "/";
        "--chdir";
        "/usr";
        "--";
        "true";
      ])
    args;
  is_false ~msg:"scoped reads never expose the host root via --ro-bind / /"
    (List.exists (String.equal "--tmpfs") args
    &&
    let rec seq = function
      | "--ro-bind" :: "/" :: "/" :: _ -> true
      | _ :: rest -> seq rest
      | [] -> false
    in
    seq args)

let bubblewrap_network_enabled_golden () =
  let args =
    bubblewrap_lowered
      (confined ~network:Policy.Network.Enabled ())
      ~cwd:(abs "/tmp") ~program:"true" []
  in
  is_false ~msg:"enabled network does not unshare the net namespace"
    (List.exists (String.equal "--unshare-net") args)

(* The [Only] root is a writable tmpfs, so an unbound write would land in it and
   report success. The seal closes that, and it must trail [--proc]/[--dev],
   which bwrap cannot create under a sealed root. [All] binds its root read-only
   already and takes no seal. *)
let bubblewrap_seals_a_scoped_root () =
  let scoped =
    bubblewrap_lowered
      (confined ~reads:[ abs "/usr" ] ())
      ~cwd:(abs "/usr") ~program:"true" []
  in
  let rec index_of needle index = function
    | [] -> None
    | x :: _ when String.equal x needle -> Some index
    | _ :: rest -> index_of needle (index + 1) rest
  in
  (match (index_of "--remount-ro" 0 scoped, index_of "--proc" 0 scoped) with
  | Some seal, Some proc ->
      is_true ~msg:"the scoped root is sealed read-only" (seal > proc)
  | _ -> fail "a scoped bubblewrap lowering must seal its root after --proc");
  is_false ~msg:"an all-reads root is bound read-only and takes no seal"
    (List.exists
       (String.equal "--remount-ro")
       (bubblewrap_lowered (confined ()) ~cwd:(abs "/tmp") ~program:"true" []))

(* Bubblewrap creates each mount point as it goes, so a denial that sealed its
   own tmpfs in place would freeze it before a deeper clause could be mounted
   inside — and the spawn dies at setup with [Can't mkdir: Read-only file
   system], before the command runs. The empty mount is emitted in clause order;
   every seal trails the last clause. Verified against real bubblewrap 0.9.0:
   with the seal deferred, a read grant beneath a denial is readable, a write
   grant beneath it is writable, and the denied siblings stay hidden and
   unwritable. *)
let bubblewrap_seals_a_denial_after_its_descendants () =
  let denied = abs "/home/u/.config/mentat" in
  let nested = abs "/home/u/.config/mentat/skills" in
  let args =
    bubblewrap_lowered
      (confined ~reads:[ abs "/home/u"; nested ] ~denied_paths:[ denied ] ())
      ~cwd:(abs "/home/u") ~program:"true" []
  in
  let rec index_of needle index = function
    | [] -> None
    | x :: _ when String.equal x needle -> Some index
    | _ :: rest -> index_of needle (index + 1) rest
  in
  let rec seal_of path index = function
    | "--remount-ro" :: p :: _ when String.equal p path -> Some index
    | _ :: rest -> seal_of path (index + 2) rest
    | [] -> None
  in
  let rec bind_of path index = function
    | ("--ro-bind" | "--bind") :: p :: _ :: _ when String.equal p path ->
        Some index
    | _ :: rest -> bind_of path (index + 1) rest
    | [] -> None
  in
  match
    ( index_of "--tmpfs" 0 args,
      bind_of (Lpath.Abs.to_string nested) 0 args,
      seal_of (Lpath.Abs.to_string denied) 0 args )
  with
  | Some tmpfs, Some nested_bind, Some seal ->
      is_true ~msg:"the denial's empty mount precedes the clause beneath it"
        (tmpfs < nested_bind);
      is_true ~msg:"the denial is sealed only after that clause is mounted"
        (seal > nested_bind)
  | _ ->
      fail
        "a denial with a clause beneath it must emit tmpfs, then the clause, \
         then the seal"

(* A denial must survive a posture that grants nothing else, and must reach the
   identity — two policies differing only in what they deny are different
   confinements. *)
let denials_are_unfiltered_and_identified () =
  let outside = abs "/elsewhere/mentat" in
  let policy =
    confined ~writable_roots:[ abs "/work" ] ~denied_paths:[ outside ] ()
  in
  equal (list abs_value)
    ~msg:"a denied path outside every writable root is kept" [ outside ]
    (Policy.denied_paths policy);
  let identity p =
    Mentat_sandbox.identity
      (Mentat_sandbox.confined ~backend:(Ok Backend.Seatbelt) ~mutates:true p)
  in
  is_false ~msg:"denying a path changes the durable identity"
    (Mentat_sandbox.Identity.equal (identity policy)
       (identity (confined ~writable_roots:[ abs "/work" ] ())))

(* A grant is a policy widening, so the resolution law is the whole mechanism:
   it must reach the lowering, it must not disturb the clauses already there,
   and — the part a caller depends on — the deny set must keep winning beneath
   it, because that is what stops a grant over a tree from buying back a path
   the posture removed. *)
let a_grant_widens_without_defeating_a_denial () =
  let policy =
    confined
      ~reads:[ abs "/work" ]
      ~writable_roots:[ abs "/work" ]
      ~denied_paths:[ abs "/work/.mentat" ]
      ()
  in
  let granted =
    match Policy.grant policy [ (abs "/cache/dune", Policy.Access.Write) ] with
    | Ok granted -> granted
    | Error (path, denied) ->
        failf "granting %a was refused by %a" Abs.pp path Abs.pp denied
  in
  is_true ~msg:"the granted path is writable"
    (List.exists
       (Abs.equal (abs "/cache/dune"))
       (Policy.writable_roots granted));
  equal (list abs_value) ~msg:"the denial is untouched by a grant elsewhere"
    [ abs "/work/.mentat" ]
    (Policy.denied_paths granted);
  is_true ~msg:"the clauses already present survive"
    (List.exists (Abs.equal (abs "/work")) (Policy.writable_roots granted));
  (* A grant over the tree that contains a denial is admitted, and the deeper
     denial still resolves inside it. *)
  match Policy.grant policy [ (abs "/work/sub", Policy.Access.Write) ] with
  | Error (path, _) ->
      failf "a grant containing no denial was refused: %a" Abs.pp path
  | Ok wider ->
      equal (list abs_value) ~msg:"a grant beside a denial leaves it standing"
        [ abs "/work/.mentat" ]
        (Policy.denied_paths wider)

(* The one case the resolution law would answer silently: [Deny] outranks a
   grant, so a grant at or beneath a denied path would be admitted and then lost.
   It is refused instead, and the refusal is directional — only the containment
   that would be defeated. *)
let a_grant_under_a_denial_is_refused () =
  let denied = abs "/home/user/.config/mentat" in
  let policy =
    confined ~writable_roots:[ abs "/work" ] ~denied_paths:[ denied ] ()
  in
  (match
     Policy.grant policy
       [ (abs "/home/user/.config/mentat/auth", Policy.Access.Write) ]
   with
  | Ok _ -> fail "a grant beneath a denied path was admitted"
  | Error (path, root) ->
      equal abs_value ~msg:"the refusal names the grant"
        (abs "/home/user/.config/mentat/auth")
        path;
      equal abs_value ~msg:"the refusal names the denial that defeats it" denied
        root);
  (match Policy.grant policy [ (denied, Policy.Access.Write) ] with
  | Ok _ -> fail "a grant of the denied path itself was admitted"
  | Error _ -> ());
  match
    Policy.grant policy [ (abs "/home/user/.config", Policy.Access.Write) ]
  with
  | Error (path, _) ->
      failf "a grant containing a denial should be admitted, refused %a" Abs.pp
        path
  | Ok wider ->
      equal (list abs_value)
        ~msg:"the denial still wins inside the granted tree" [ denied ]
        (Policy.denied_paths wider)

(* A carveout is a clause deliberately lowered inside a more permissive one —
   [.git] inside the writable workspace, the dune store inside its cache. A
   grant may not raise one back: [normalize] keeps the stronger access, so
   admitting the write would hand back exactly the path an earlier ruling took
   away, silently. The workspace case is the sharp one, because Mentat itself
   runs git, and a writable [.git/hooks] is arbitrary code on the next call. *)
let a_grant_may_not_raise_a_carveout () =
  let workspace = abs "/work" in
  let git = abs "/work/.git" in
  let policy =
    Policy.make
      ~entries:[ (workspace, Policy.Access.Write); (git, Policy.Access.Read) ]
      ~reads_default:Policy.Denied ~network:Policy.Network.Restricted
  in
  (match Policy.grant policy [ (git, Policy.Access.Write) ] with
  | Ok _ -> fail "a write grant over a read carveout must be refused"
  | Error (path, root) ->
      equal abs_value ~msg:"the refusal names the grant" git path;
      equal abs_value ~msg:"and the carveout that defeats it" git root);
  (match
     Policy.grant policy [ (abs "/work/.git/hooks", Policy.Access.Write) ]
   with
  | Ok _ -> fail "a write grant beneath a read carveout must be refused"
  | Error _ -> ());
  (* A read root is not a carveout: nothing lowered it, so a grant beneath it is
     the ordinary widening this exists to serve. *)
  let open_reads =
    Policy.make
      ~entries:[ (abs "/usr", Policy.Access.Read) ]
      ~reads_default:Policy.Denied ~network:Policy.Network.Restricted
  in
  match
    Policy.grant open_reads [ (abs "/usr/local/x", Policy.Access.Write) ]
  with
  | Ok _ -> ()
  | Error (path, _) ->
      failf "a grant beneath a plain read root must be admitted, refused %a"
        Abs.pp path

(* A grant is a route, not a stored posture: the sealed value it returns lowers
   and reports as an enforced confined command — never as an escape — and the
   seal it was made from is unchanged. *)
let a_granted_seal_still_confines () =
  let policy =
    confined ~reads:[ abs "/work" ] ~writable_roots:[ abs "/work" ] ()
  in
  let sandbox = sealed policy in
  let granted =
    match
      Mentat_sandbox.grant sandbox [ (abs "/work/deep", Policy.Access.Write) ]
    with
    | Ok granted -> granted
    | Error error -> fail (Error.message error)
  in
  (match Mentat_sandbox.evidence granted with
  | Evidence.Enforced _ -> ()
  | _ -> fail "a granted command reports enforced evidence, not an escape");
  is_false ~msg:"the widened lowering differs from the one it widened"
    (Mentat_digest.equal
       (Mentat_sandbox.Identity.digest (Mentat_sandbox.identity granted))
       (Mentat_sandbox.Identity.digest (Mentat_sandbox.identity sandbox)));
  equal policy_value ~msg:"the seal the grant was made from is untouched" policy
    (Option.get (Mentat_sandbox.policy sandbox));
  (* An unconfined route already admits what a grant asks for. *)
  match
    Mentat_sandbox.grant Mentat_sandbox.direct
      [ (abs "/x", Policy.Access.Write) ]
  with
  | Ok _ -> ()
  | Error error -> fail (Error.message error)

(* Both backends must put the denial last, or a read or write root emitted
   after it would win. *)
let denials_are_lowered_last () =
  let denied = abs "/elsewhere/mentat" in
  let policy =
    confined
      ~reads:[ abs "/usr" ]
      ~writable_roots:[ abs "/usr" ]
      ~denied_paths:[ denied ] ()
  in
  let bwrap = bubblewrap_lowered policy ~cwd:(abs "/usr") ~program:"true" [] in
  let rec index_of needle index = function
    | [] -> None
    | x :: _ when String.equal x needle -> Some index
    | _ :: rest -> index_of needle (index + 1) rest
  in
  (match (index_of "/elsewhere/mentat" 0 bwrap, index_of "--bind" 0 bwrap) with
  | Some mask, Some bind ->
      is_true ~msg:"the mask follows every bind" (mask > bind)
  | _ -> fail "a denied path must be masked in the bubblewrap lowering");
  is_true ~msg:"the mask is remounted read-only, not merely emptied"
    (List.exists (String.equal "--remount-ro") bwrap);
  let sbpl, params = seatbelt_sbpl policy in
  contains ~msg:"seatbelt denies reads and writes at the denied path"
    ~sub:"(deny file-read* file-write*" sbpl;
  is_true ~msg:"the denied path is a parameter, never profile text"
    (List.exists
       (fun (_, value) -> String.equal value "/elsewhere/mentat")
       params);
  not_contains ~msg:"a deny-free profile emits no deny section"
    ~sub:"(deny file-read* file-write*"
    (fst (seatbelt_sbpl (confined ~reads:[ abs "/usr" ] ())))

let bubblewrap_uses_strict_ro_bind () =
  (* Hardening #2: carveouts use strict [--ro-bind], never [--ro-bind-try],
     which would fail open on a mid-flight deletion. *)
  let policy =
    confined
      ~writable_roots:[ abs "/work" ]
      ~protected_paths:[ abs "/work/.git" ]
      ()
  in
  let args = bubblewrap_lowered policy ~cwd:(abs "/tmp") ~program:"true" [] in
  is_false ~msg:"no --ro-bind-try token is ever emitted"
    (List.exists (String.equal "--ro-bind-try") args);
  is_false ~msg:"no token carries a -try suffix"
    (List.exists (fun a -> String.includes ~affix:"-try" a) args);
  is_true ~msg:"the protected carveout is a strict --ro-bind"
    (let rec seq = function
       | "--ro-bind" :: "/work/.git" :: "/work/.git" :: _ -> true
       | _ :: rest -> seq rest
       | [] -> false
     in
     seq args)

(* Route constructors — evidence table, fail-closed refusal, coupling. *)

let workspace_policy = confined ~writable_roots:[ abs "/work" ] ()

let route_evidence_table () =
  (* RFC L2: the backend-outcome -> evidence class table, fixed at seal time.
     A forgotten probe outcome is a type error ([~backend] is required), so the
     old fail-closed-default case is unrepresentable rather than tested. *)
  (match Sandbox.evidence (sealed workspace_policy) with
  | Evidence.Enforced { backend; _ } ->
      equal string ~msg:"confined+Ok -> Enforced with the backend id"
        "macos-seatbelt" (Backend.id backend)
  | _ -> fail "confined+Ok should be Enforced evidence");
  (match Sandbox.evidence (refused_sealed workspace_policy) with
  | Evidence.Refused error ->
      equal error_value ~msg:"confined+Error -> Refused with the error"
        (Error.Unavailable "no backend") error
  | _ -> fail "confined+Error should be Refused evidence");
  is_true ~msg:"direct -> Not_requested"
    (match Sandbox.evidence Sandbox.direct with
    | Evidence.Not_requested -> true
    | _ -> false);
  is_true ~msg:"external -> Declared_external"
    (match Sandbox.evidence Sandbox.external_ with
    | Evidence.Declared_external -> true
    | _ -> false)

let route_policy_projection () =
  (match Sandbox.policy (sealed workspace_policy) with
  | Some policy ->
      equal policy_value ~msg:"an enforced route carries its policy"
        workspace_policy policy
  | None -> fail "an enforced route must carry a policy");
  (match Sandbox.policy (refused_sealed workspace_policy) with
  | Some policy ->
      equal policy_value ~msg:"a refused route still carries its policy"
        workspace_policy policy
  | None -> fail "a refused route must carry a policy");
  is_true ~msg:"direct has no policy" (Sandbox.policy Sandbox.direct = None);
  is_true ~msg:"external has no policy" (Sandbox.policy Sandbox.external_ = None)

let evidence_is_fixed_across_lowerings () =
  let sandbox = sealed workspace_policy in
  let first = lowered sandbox ~cwd:(abs "/work") ~program:"true" [] in
  let second = lowered sandbox ~cwd:(abs "/work/sub") ~program:"true" [] in
  is_true ~msg:"lowering returns argv, not evidence"
    (first <> [] && second <> []);
  equal evidence_value ~msg:"the sealed evidence is identical across lowerings"
    (Sandbox.evidence sandbox) (Sandbox.evidence sandbox)

let refused_route_refuses_every_command () =
  (* RFC L3: an unavailable backend refuses every command — fail-closed. *)
  let sandbox = refused_sealed workspace_policy in
  match Sandbox.lower_argv sandbox ~cwd:(abs "/work") [ "true" ] with
  | Error error ->
      equal error_value ~msg:"the lowering error is the sealed refusal"
        (Error.Unavailable "no backend") error
  | Ok _ -> fail "a refused route must lower nothing"

let route_couples_profile_to_policy () =
  (* RFC L5: the constructor receives a Backend selector, never a profile, so
     the sealed policy, evidence, obligations, and identity always describe the
     same policy. Injecting a foreign profile is unrepresentable at the type
     level; the observable coupling is that the sealed policy is exactly the
     input and the evidence backend matches the injected selector. *)
  List.iter
    (fun backend ->
      let sandbox = sealed ~backend workspace_policy in
      (match Sandbox.policy sandbox with
      | Some policy ->
          equal policy_value ~msg:"the sealed policy is exactly the input"
            workspace_policy policy
      | None -> fail "a confined route must carry a policy");
      match Sandbox.evidence sandbox with
      | Evidence.Enforced { backend = recorded; _ } ->
          is_true ~msg:"evidence backend matches the injected selector"
            (Backend.equal backend recorded)
      | _ -> fail "an enforced seal should carry Enforced evidence")
    Backend.all

let digest_stability_across_construction () =
  (* Hardening #17: equal policy => equal profile => equal Evidence and
     Identity digest; a different policy differs. Two policies built from
     differently ordered, duplicated inputs normalize to the same value. *)
  let a =
    confined
      ~writable_roots:[ abs "/usr"; abs "/tmp" ]
      ~protected_paths:[ abs "/usr/bin"; abs "/usr/lib" ]
      ()
  in
  let b =
    confined
      ~writable_roots:[ abs "/tmp"; abs "/usr"; abs "/usr" ]
      ~protected_paths:[ abs "/usr/lib"; abs "/usr/bin" ]
      ()
  in
  is_true ~msg:"differently-ordered inputs normalize to an equal policy"
    (Policy.equal a b);
  is_true ~msg:"equal policies produce an equal enforced-profile digest"
    (Evidence.equal (Sandbox.evidence (sealed a)) (Sandbox.evidence (sealed b)));
  is_true ~msg:"equal policies produce an equal identity"
    (Identity.equal (identity_of a) (identity_of b));
  is_false
    ~msg:"a different policy produces a different enforced-profile digest"
    (Evidence.equal
       (Sandbox.evidence (sealed a))
       (Sandbox.evidence (sealed (confined ()))))

let sealing_is_pure_and_total () =
  (* RFC L1: equal (policy, backend outcome) give equal seals in every
     projection. *)
  let a = sealed ~backend:Backend.Bubblewrap workspace_policy in
  let b = sealed ~backend:Backend.Bubblewrap workspace_policy in
  equal evidence_value ~msg:"equal evidence" (Sandbox.evidence a)
    (Sandbox.evidence b);
  is_true ~msg:"equal identity"
    (Identity.equal (Sandbox.identity a) (Sandbox.identity b));
  is_true ~msg:"equal escalation stance"
    (match (Sandbox.escalation a, Sandbox.escalation b) with
    | Sandbox.Available, Sandbox.Available -> true
    | _ -> false)

(* Escalation stance. *)

let escalation_stances () =
  is_true ~msg:"workspace-write is escalation-available"
    (match Sandbox.escalation (sealed workspace_policy) with
    | Sandbox.Available -> true
    | _ -> false);
  is_true ~msg:"a no-mutation posture denies escalation"
    (match Sandbox.escalation (sealed ~mutates:false (confined ())) with
    | Sandbox.Denied Error.Escalation_denied -> true
    | _ -> false);
  (* The stance is the posture's own answer, not a reading of the writable list:
     a no-mutation route granted scratch space must not thereby acquire an
     approval-shaped escape. *)
  is_true ~msg:"granting a no-mutation route a temp root buys no escalation"
    (match
       Sandbox.escalation
         (sealed ~mutates:false (confined ~writable_roots:[ abs "/tmp" ] ()))
     with
    | Sandbox.Denied Error.Escalation_denied -> true
    | _ -> false);
  is_true ~msg:"a mutating route with no writable root is still available"
    (match Sandbox.escalation (sealed ~mutates:true (confined ())) with
    | Sandbox.Available -> true
    | _ -> false);
  is_true ~msg:"direct ignores escalation"
    (match Sandbox.escalation Sandbox.direct with
    | Sandbox.Ignored -> true
    | _ -> false);
  is_true ~msg:"external ignores escalation"
    (match Sandbox.escalation Sandbox.external_ with
    | Sandbox.Ignored -> true
    | _ -> false)

let escalation_is_shape_based_not_availability_based () =
  (* Escalation is a permission-gated unconfined escape determined by the policy
     shape (workspace-write), orthogonal to whether the backend enforced. A
     refused workspace-write seal still reports Available, because reaching an
     escalated launch requires a separate approval and drops the sandbox
     entirely. *)
  is_true ~msg:"a refused workspace-write seal is still escalation-available"
    (match Sandbox.escalation (refused_sealed workspace_policy) with
    | Sandbox.Available -> true
    | _ -> false)

(* lower_argv / lower_escalated_argv. *)

let lower_argv_appends_command_verbatim () =
  (* The enforcing prefix cannot rewrite, reorder, or drop the wrapped command:
     the lowered argv always ends with program :: args verbatim, even when the
     tokens are empty strings or shell metacharacters. *)
  let command = [ "sh"; "-c"; "rm -rf / ; echo $HOME `id`"; "" ] in
  let seatbelt =
    lowered (sealed workspace_policy) ~cwd:(abs "/work") ~program:"sh"
      [ "-c"; "rm -rf / ; echo $HOME `id`"; "" ]
  in
  let tail tokens =
    let n = List.length tokens in
    List.filteri (fun i _ -> i >= n - 4) tokens
  in
  equal (list string) ~msg:"seatbelt lowering ends with the command verbatim"
    command (tail seatbelt);
  is_true ~msg:"seatbelt lowering separates the command with --"
    (List.exists (String.equal "--") seatbelt)

let lower_argv_enforces_cwd_containment () =
  (* RFC L9 / hardening #8: a confined cwd must be within the readable roots.
     Purely lexical: no filesystem is touched. *)
  let sandbox =
    sealed (confined ~reads:[ abs "/work" ] ~writable_roots:[ abs "/work" ] ())
  in
  ignore
    (require_ok ~msg:"a cwd inside the read roots is accepted"
       (Sandbox.lower_argv sandbox ~cwd:(abs "/work/sub") [ "true" ]));
  match Sandbox.lower_argv sandbox ~cwd:(abs "/elsewhere") [ "true" ] with
  | Error error ->
      equal error_value
        ~msg:"a cwd outside the read roots is Cwd_outside_scope with the cwd"
        (Error.Cwd_outside_scope (abs "/elsewhere"))
        error
  | Ok _ -> fail "an out-of-scope cwd must be refused"

let lower_argv_passes_unconfined_routes_verbatim () =
  equal (list string) ~msg:"direct lowering is the command verbatim"
    [ "sh"; "-c"; "true" ]
    (lowered Sandbox.direct ~cwd:(abs "/anywhere") ~program:"sh"
       [ "-c"; "true" ]);
  equal (list string) ~msg:"external lowering is the command verbatim"
    [ "true" ]
    (lowered Sandbox.external_ ~cwd:(abs "/x") ~program:"true" [])

let lower_argv_validates_argv () =
  (* OS argv cannot represent an empty program or NUL bytes. Validation mints
     structured errors on every route; its enforcement home is the single
     launch boundary, which lowers every command through here. *)
  let check ~msg lower =
    (match lower [] with
    | Error Error.Empty_program -> ()
    | _ -> fail (msg ^ ": empty argv must be Empty_program"));
    (match lower [ ""; "a" ] with
    | Error Error.Empty_program -> ()
    | _ -> fail (msg ^ ": empty program must be Empty_program"));
    (match lower [ "pro\000gram" ] with
    | Error (Error.Nul_in_argv { index = 0 }) -> ()
    | _ -> fail (msg ^ ": NUL in the program must be Nul_in_argv index 0"));
    match lower [ "prog"; "ok"; "a\000b" ] with
    | Error (Error.Nul_in_argv { index = 2 }) -> ()
    | _ -> fail (msg ^ ": NUL in an argument must be Nul_in_argv at its index")
  in
  let ordinary sandbox argv =
    Sandbox.lower_argv sandbox ~cwd:(abs "/work") argv
  in
  check ~msg:"confined" (ordinary (sealed workspace_policy));
  check ~msg:"refused" (ordinary (refused_sealed workspace_policy));
  check ~msg:"direct" (ordinary Sandbox.direct);
  check ~msg:"external" (ordinary Sandbox.external_);
  check ~msg:"escalated" (fun argv ->
      match Sandbox.escalated (sealed workspace_policy) with
      | Ok escalated -> Sandbox.lower_argv escalated ~cwd:(abs "/x") argv
      | Error error -> fail (Error.message error))

let escalation_keeps_the_denials_and_drops_the_rest () =
  (* Escalation is a widening, not a discard: it opens the filesystem and the
     network and keeps exactly the denied paths, because those are denied so a
     later unconfined process cannot be handed authority through them — the
     session store most of all, which a command able to write it could use to
     approve itself. The read carveouts are deliberately not kept. *)
  let denied = abs "/home/u/.local/state/mentat" in
  let policy =
    confined
      ~reads:[ abs "/work" ]
      ~writable_roots:[ abs "/work" ]
      ~protected_paths:[ abs "/work/.git" ]
      ~denied_paths:[ denied ] ()
  in
  let sandbox = sealed policy in
  let out_of_scope = abs "/outside" in
  is_true ~msg:"lower_argv rejects the out-of-scope cwd"
    (Result.is_error (Sandbox.lower_argv sandbox ~cwd:out_of_scope [ "true" ]));
  match Sandbox.escalated sandbox with
  | Error error -> fail (Error.message error)
  | Ok escalated -> (
      let escalated_policy = Option.get (Sandbox.policy escalated) in
      equal (list abs_value) ~msg:"the denial survives the escalation"
        [ denied ]
        (Policy.denied_paths escalated_policy);
      is_true ~msg:"the root is writable"
        (List.exists
           (fun p -> Lpath.Abs.is_root p)
           (Policy.writable_roots escalated_policy));
      is_true ~msg:"reads are open"
        (match Policy.reads_default escalated_policy with
        | Policy.All -> true
        | Policy.Denied -> false);
      is_true ~msg:"the network is open"
        (Policy.Network.equal
           (Policy.network escalated_policy)
           Policy.Network.Enabled);
      is_false ~msg:"a read carveout is not kept"
        (List.exists
           (fun p -> Lpath.Abs.equal p (abs "/work/.git"))
           (Policy.readable_roots escalated_policy));
      (* Still enforced, and it says so: an escalated command must not report
         that nothing confined it. *)
      (match Sandbox.evidence escalated with
      | Evidence.Enforced _ -> ()
      | _ -> fail "an escalated command is still an enforced one");
      (* The out-of-scope cwd is accepted — that is the point of escalating. *)
      match Sandbox.lower_argv escalated ~cwd:out_of_scope [ "true" ] with
      | Ok _ -> ()
      | Error error -> fail (Error.message error))

let lower_escalated_refuses_denied_and_ignored () =
  (match Sandbox.escalated (sealed ~mutates:false (confined ())) with
  | Error Error.Escalation_denied ->
      (* Semantic pin: the read-only refusal message is product-neutral — no
         --sandbox flag hint leaks from the library. *)
      equal string ~msg:"read-only escalation refusal message"
        "the sealed posture promises no mutation: a read-only sandbox admits \
         neither an escalation nor a write grant"
        (Error.message Error.Escalation_denied)
  | _ -> fail "read-only escalation must be Escalation_denied");
  match Sandbox.escalated Sandbox.direct with
  | Error Error.Escalation_irrelevant -> ()
  | _ -> fail "direct escalation must be Escalation_irrelevant"

(* obligations. *)

let obligation_repr o =
  ( (match Sandbox.Obligation.kind o with
    | Sandbox.Obligation.Exists -> "exists"
    | Sandbox.Obligation.Directory -> "directory"),
    Sandbox.Obligation.path o )

let obligations_enumerate_paths_and_kinds () =
  (* RFC L10: readable and protected paths are Exists; writable roots are
     Directory; deduplicated by path keeping the strongest kind, in canonical
     path order. A writable root is also folded into the read set, so its single
     obligation must be the stronger Directory. *)
  let policy =
    confined
      ~reads:[ abs "/data" ]
      ~writable_roots:[ abs "/work" ]
      ~protected_paths:[ abs "/work/.git" ]
      ()
  in
  let obligations =
    List.map obligation_repr (Sandbox.obligations (sealed policy))
  in
  equal
    (list (pair string abs_value))
    ~msg:"obligations enumerate the right paths and kinds"
    [
      ("exists", abs "/data");
      ("directory", abs "/work");
      ("exists", abs "/work/.git");
    ]
    obligations

let obligations_are_empty_for_unconfined_and_refused () =
  is_true ~msg:"direct has no obligations"
    (Sandbox.obligations Sandbox.direct = []);
  is_true ~msg:"external has no obligations"
    (Sandbox.obligations Sandbox.external_ = []);
  is_true ~msg:"a refused confined seal has no obligations"
    (Sandbox.obligations (refused_sealed workspace_policy) = [])

(* admits — the startup gate (3x4 requirement x evidence table). *)

let admit_ok req sandbox msg =
  is_true ~msg (Result.is_ok (Sandbox.admits req sandbox))

let admit_unenforceable req sandbox msg =
  is_true ~msg
    (match Sandbox.admits req sandbox with
    | Error (Requirement.Rejection.Unenforceable _) -> true
    | _ -> false)

let admit_external req sandbox msg =
  is_true ~msg
    (match Sandbox.admits req sandbox with
    | Error Requirement.Rejection.External_not_enforced -> true
    | _ -> false)

let admits_reproduces_the_host_gate () =
  (* RFC L7 / hardening #4: the sealed-evidence gate, over all 3x4 cells. *)
  let enforced = sealed workspace_policy in
  let refused = refused_sealed workspace_policy in
  let not_requested = Sandbox.direct in
  let external_ = Sandbox.external_ in
  (* Off admits every posture. *)
  admit_ok Requirement.Off enforced "off admits enforced";
  admit_ok Requirement.Off refused "off admits refused";
  admit_ok Requirement.Off not_requested "off admits not_requested";
  admit_ok Requirement.Off external_ "off admits external";
  (* Enforced_or_external rejects only a refused confinement. *)
  admit_ok Requirement.Enforced_or_external enforced "e-or-x admits enforced";
  admit_ok Requirement.Enforced_or_external external_ "e-or-x admits external";
  admit_ok Requirement.Enforced_or_external not_requested
    "e-or-x admits not_requested";
  admit_unenforceable Requirement.Enforced_or_external refused
    "e-or-x rejects refused as unenforceable";
  (* Enforced rejects refused and external. *)
  admit_ok Requirement.Enforced enforced "enforced admits enforced";
  admit_ok Requirement.Enforced not_requested
    "enforced admits not_requested (explicit unconfined mode)";
  admit_external Requirement.Enforced external_
    "enforced rejects external as external_not_enforced";
  admit_unenforceable Requirement.Enforced refused
    "enforced rejects refused as unenforceable"

(* Evidence codec. *)

let enforced_profile_digest sandbox =
  match Sandbox.evidence sandbox with
  | Evidence.Enforced { profile; _ } -> profile
  | _ -> fail "expected enforced evidence"

let evidence_json_shapes () =
  let obj fields =
    Json.object'
      (List.map (fun (name, value) -> Json.mem (Json.name name) value) fields)
  in
  is_true ~msg:"not_requested json"
    (Json.equal
       (obj [ ("kind", json_string "not_requested") ])
       (Evidence.to_json (Sandbox.evidence Sandbox.direct)));
  is_true ~msg:"declared_external json"
    (Json.equal
       (obj [ ("kind", json_string "declared_external") ])
       (Evidence.to_json (Sandbox.evidence Sandbox.external_)));
  (let sandbox = sealed workspace_policy in
   let profile = enforced_profile_digest sandbox in
   is_true ~msg:"enforced json carries backend and profile_hash"
     (Json.equal
        (obj
           [
             ("kind", json_string "enforced");
             ("backend", json_string "macos-seatbelt");
             ("profile_hash", json_string (Digest.to_hex profile));
           ])
        (Evidence.to_json (Sandbox.evidence sandbox))));
  (* Refused carries both a display "reason" and the structured "error" a
     consumer branches on by constructor. Stale_policy is the twin-minted case:
     a failed obligation discharge speaks this vocabulary. *)
  let error = Error.Stale_policy { path = abs "/work" } in
  match Evidence.to_json (Evidence.refused error) with
  | Jsont.Object (members, _) ->
      is_true ~msg:"refused kind"
        (match Json.find_mem "kind" members with
        | Some (_, Jsont.String (v, _)) -> String.equal v "refused"
        | _ -> false);
      is_true ~msg:"refused carries a display reason"
        (match Json.find_mem "reason" members with
        | Some (_, Jsont.String (v, _)) -> String.equal v (Error.message error)
        | _ -> false);
      is_true ~msg:"refused carries the structured error"
        (match Json.find_mem "error" members with
        | Some (_, structured) -> Json.equal structured (Error.to_json error)
        | None -> false)
  | _ -> fail "refused evidence must encode to a JSON object"

let evidence_cases_are_distinct () =
  let cases =
    [
      Sandbox.evidence Sandbox.direct;
      Sandbox.evidence (sealed workspace_policy);
      Evidence.refused (Error.Unavailable "x");
      Sandbox.evidence Sandbox.external_;
    ]
  in
  List.iteri
    (fun i a ->
      List.iteri
        (fun j b ->
          if i = j then
            is_true ~msg:"evidence equals itself" (Evidence.equal a b)
          else
            is_false ~msg:"distinct postures are unequal" (Evidence.equal a b))
        cases)
    cases;
  is_false ~msg:"enforced differs by backend"
    (Evidence.equal
       (Sandbox.evidence (sealed workspace_policy))
       (Sandbox.evidence (sealed ~backend:Backend.Bubblewrap workspace_policy)));
  is_false ~msg:"refused differs by error"
    (Evidence.equal
       (Evidence.refused (Error.Unavailable "x"))
       (Evidence.refused (Error.Stale_policy { path = abs "/x" })))

(* Identity — scratch-invariant confinement fingerprint (RFC L8). *)

let identity_domain = "mentat.sandbox.identity.v1"

(* Independently spell the documented wire framing (length-framed parts under
   the versioned domain — [Mentat_digest.derive]'s framing law) to pin the
   domain string and framing format, without reaching into the library's
   internals. *)
let framed_digest parts =
  let buffer = Buffer.create 64 in
  List.iter
    (fun part ->
      Buffer.add_string buffer (string_of_int (String.length part));
      Buffer.add_char buffer ':';
      Buffer.add_string buffer part)
    (identity_domain :: parts);
  Digest.string (Buffer.contents buffer)

let identity_domain_and_framing () =
  is_true ~msg:"not_requested digest uses the documented domain and framing"
    (Digest.equal
       (framed_digest [ "not_requested" ])
       (Identity.digest (Sandbox.identity Sandbox.direct)));
  is_true ~msg:"declared_external digest uses the documented domain and framing"
    (Digest.equal
       (framed_digest [ "declared_external" ])
       (Identity.digest (Sandbox.identity Sandbox.external_)));
  is_true ~msg:"refused digest uses the documented domain and framing"
    (Digest.equal
       (framed_digest [ "refused" ])
       (Identity.digest (Sandbox.identity (refused_sealed workspace_policy))))

(* Byte-stability pins across the [Mentat_digest.derive] refactor. The
   class-only digests below were computed from the pre-derive implementation
   (the hand-rolled length framing) and must never change: a session contract
   persists identities, and a digest shift would refuse every pending
   invocation. The enforced pins were minted when the profile canonicalization
   moved onto [derive ~domain:"mentat.sandbox.profile.v1"] and pin the current
   enforced derivation end-to-end (policy: scratch /tmp, reads Only [/data],
   writable [/work], protected [/work/.git], network restricted). The Seatbelt
   pin was re-minted when the profile gained the Unix-socket [network-bind]/
   [network-outbound] allow scoped to the writable roots (so build tools can
   bind their RPC socket), and again when it gained the [com.apple.FSEvents]
   mach-lookup (so a confined [dune build --watch]'s file watcher can start);
   the Bubblewrap pin was re-minted when [--proc] was hoisted ahead of the
   clause mounts, so a clause naming [/proc] wins over the procfs mount the
   way the resolution law says it must. *)
let identity_digest_pins () =
  equal string ~msg:"not_requested identity digest is byte-stable"
    "5eb60082fd887b2d9988623b099f340426ef07e65f11c7b6ecf81cf3d01dea47"
    (Digest.to_hex (Identity.digest (Sandbox.identity Sandbox.direct)));
  equal string ~msg:"declared_external identity digest is byte-stable"
    "b79f1aebf5801657bd51568ae49cca0188222ca3fc21adaa3274b2f6196593f8"
    (Digest.to_hex (Identity.digest (Sandbox.identity Sandbox.external_)));
  equal string ~msg:"refused identity digest is byte-stable"
    "50ec9e852f77a0604c09ca5459e1cef3d560c5168b89a0459156ca718bbb2364"
    (Digest.to_hex
       (Identity.digest (Sandbox.identity (refused_sealed workspace_policy))));
  let pinned_policy =
    confined
      ~reads:[ abs "/data" ]
      ~writable_roots:[ abs "/work" ]
      ~protected_paths:[ abs "/work/.git" ]
      ()
  in
  equal string ~msg:"seatbelt enforced identity digest golden"
    "4701dfe5e27041f434b58c65a98b2b6812f4a837589a42ae87ba98d66872c69a"
    (Digest.to_hex (Identity.digest (identity_of pinned_policy)));
  equal string ~msg:"bubblewrap enforced identity digest golden"
    "3c45f1b71d50ebc65eb0b88551cc2aec352f542c709ce094dd9f4d255204858a"
    (Digest.to_hex
       (Identity.digest (identity_of ~backend:Backend.Bubblewrap pinned_policy)))

let identity_changes_on_confinement_change () =
  let base =
    confined
      ~reads:[ abs "/data" ]
      ~writable_roots:[ abs "/work" ]
      ~protected_paths:[ abs "/work/.git" ]
      ~network:Policy.Network.Restricted ()
  in
  let base_id = identity_of base in
  let differs ~msg policy =
    is_false ~msg (Identity.equal base_id (identity_of policy))
  in
  differs ~msg:"widening a writable root flips the identity"
    (confined
       ~reads:[ abs "/data" ]
       ~writable_roots:[ abs "/work"; abs "/extra" ]
       ~protected_paths:[ abs "/work/.git" ]
       ());
  differs ~msg:"flipping the network flips the identity"
    (confined
       ~reads:[ abs "/data" ]
       ~writable_roots:[ abs "/work" ]
       ~protected_paths:[ abs "/work/.git" ]
       ~network:Policy.Network.Enabled ());
  differs ~msg:"adding a read root flips the identity"
    (confined
       ~reads:[ abs "/data"; abs "/more" ]
       ~writable_roots:[ abs "/work" ]
       ~protected_paths:[ abs "/work/.git" ]
       ());
  differs ~msg:"changing a protected path flips the identity"
    (confined
       ~reads:[ abs "/data" ]
       ~writable_roots:[ abs "/work" ]
       ~protected_paths:[ abs "/work/.mentat" ]
       ());
  is_false ~msg:"changing the backend flips the identity"
    (Identity.equal base_id (identity_of ~backend:Backend.Bubblewrap base))

let identity_class_separation () =
  (* The child environment is excluded from the identity structurally: this
     library never sees an environment, so there is no env-value case left to
     test — RFC L8's env-invariance clause is now a type-level fact. *)
  let enforced = identity_of workspace_policy in
  let not_requested = Sandbox.identity Sandbox.direct in
  let external_ = Sandbox.identity Sandbox.external_ in
  let refused = Sandbox.identity (refused_sealed workspace_policy) in
  let all = [ enforced; not_requested; external_; refused ] in
  List.iteri
    (fun i a ->
      List.iteri
        (fun j b ->
          if i <> j then
            is_false ~msg:"distinct evidence classes have distinct identities"
              (Identity.equal a b))
        all)
    all

let identity_jsont_round_trips () =
  let round_trip label sandbox =
    let identity = Sandbox.identity sandbox in
    match Json.encode Identity.jsont identity with
    | Error message -> failf "%s: encode failed: %s" label message
    | Ok json -> (
        match Json.decode Identity.jsont json with
        | Error message -> failf "%s: decode failed: %s" label message
        | Ok reloaded ->
            is_true
              ~msg:(label ^ ": round-trip preserves the digest")
              (Digest.equal (Identity.digest identity)
                 (Identity.digest reloaded)))
  in
  round_trip "enforced" (sealed ~backend:Backend.Bubblewrap workspace_policy);
  round_trip "not_requested" Sandbox.direct;
  round_trip "declared_external" Sandbox.external_;
  round_trip "refused" (refused_sealed workspace_policy)

let identity_decode_rejects_non_canonical () =
  let obj fields =
    Json.object'
      (List.map (fun (name, value) -> Json.mem (Json.name name) value) fields)
  in
  let valid_hex = Digest.to_hex (Digest.string "profile") in
  let rejects label json =
    is_true ~msg:label (Result.is_error (Json.decode Identity.jsont json))
  in
  rejects "enforced without a backend or profile"
    (obj [ ("class", json_string "enforced") ]);
  rejects "enforced without a profile"
    (obj
       [
         ("class", json_string "enforced");
         ("backend", json_string "macos-seatbelt");
       ]);
  rejects "a non-enforced class carrying a backend"
    (obj
       [
         ("class", json_string "not_requested");
         ("backend", json_string "macos-seatbelt");
       ]);
  rejects "a non-enforced class carrying a profile"
    (obj
       [ ("class", json_string "refused"); ("profile", json_string valid_hex) ]);
  rejects "an unknown class" (obj [ ("class", json_string "loose") ]);
  rejects "an unknown backend under enforced"
    (obj
       [
         ("class", json_string "enforced");
         ("backend", json_string "windows-appcontainer");
         ("profile", json_string valid_hex);
       ])

(* Suite. *)

let () =
  run "mentat.sandbox"
    [
      (* Error *)
      test "error constructors are structured and distinct"
        error_constructors_are_distinct;
      test "error messages carry the structured fields"
        error_messages_carry_fields;
      test "error json is built from the constructors" error_json_shape;
      (* Policy *)
      test "policy distinguishes network state" policy_distinguishes_network;
      test "policy keeps every clause" policy_keeps_every_clause;
      test "a grant widens without defeating a denial"
        a_grant_widens_without_defeating_a_denial;
      test "a grant under a denial is refused" a_grant_under_a_denial_is_refused;
      test "a grant may not raise a carveout" a_grant_may_not_raise_a_carveout;
      test "a granted seal still confines" a_granted_seal_still_confines;
      test "bubblewrap seals a denial after its descendants"
        bubblewrap_seals_a_denial_after_its_descendants;
      test "policy collapses only duplicate paths"
        policy_collapses_only_duplicate_paths;
      policy_entries_are_ordered_shallowest_first ();
      test "a root grant is refused" a_root_grant_is_refused;
      test "policy folds writable into reads" policy_folds_writable_into_reads;
      test "policy denials participate in equality"
        policy_denials_participate_in_equality;
      (* Backend / Requirement / Network *)
      test "backend identity and order" backend_identity;
      test "backend of_id round-trips" backend_of_id_round_trips;
      test "enforcing executables are fixed and absolute"
        backend_executables_are_fixed_and_absolute;
      test "requirement spellings round-trip" requirement_round_trips;
      test "network spellings round-trip" network_round_trips;
      (* Seatbelt golden *)
      test "seatbelt read-only golden" seatbelt_read_only_golden;
      test "seatbelt scoped-reads golden" seatbelt_scoped_reads_golden;
      test "seatbelt carveout golden" seatbelt_carveout_golden;
      test "seatbelt nested roots share carveouts"
        seatbelt_nested_roots_share_carveouts;
      test "seatbelt network-enabled golden" seatbelt_network_enabled_golden;
      test "seatbelt denies the launchd agent endpoints last"
        seatbelt_agent_socket_denied_last;
      test "seatbelt puts no path byte in the profile text"
        seatbelt_no_path_enters_the_text;
      test "seatbelt generation is deterministic"
        seatbelt_generation_is_deterministic;
      (* Bubblewrap golden *)
      test "bubblewrap read-only golden" bubblewrap_read_only_golden;
      test "bubblewrap scoped-reads golden" bubblewrap_scoped_reads_golden;
      test "bubblewrap network-enabled golden" bubblewrap_network_enabled_golden;
      test "bubblewrap uses strict --ro-bind" bubblewrap_uses_strict_ro_bind;
      test "bubblewrap seals a scoped root" bubblewrap_seals_a_scoped_root;
      test "denials are unfiltered and identified"
        denials_are_unfiltered_and_identified;
      test "denials are lowered last" denials_are_lowered_last;
      (* Route constructors *)
      test "route evidence table" route_evidence_table;
      test "route policy projection" route_policy_projection;
      test "evidence is fixed across lowerings"
        evidence_is_fixed_across_lowerings;
      test "a refused route refuses every command"
        refused_route_refuses_every_command;
      test "the route couples the profile to the sealed policy"
        route_couples_profile_to_policy;
      test "digest stability across construction"
        digest_stability_across_construction;
      test "sealing is pure and total" sealing_is_pure_and_total;
      (* Escalation *)
      test "escalation stances" escalation_stances;
      test "escalation is shape-based, not availability-based"
        escalation_is_shape_based_not_availability_based;
      (* lower_argv / lower_escalated_argv *)
      test "lower_argv appends the command verbatim"
        lower_argv_appends_command_verbatim;
      test "lower_argv enforces lexical cwd containment"
        lower_argv_enforces_cwd_containment;
      test "lower_argv passes unconfined routes verbatim"
        lower_argv_passes_unconfined_routes_verbatim;
      test "lower_argv validates argv on every route" lower_argv_validates_argv;
      test "lower_escalated_argv drops containment and never prefixes"
        escalation_keeps_the_denials_and_drops_the_rest;
      test "lower_escalated_argv refuses denied and ignored routes"
        lower_escalated_refuses_denied_and_ignored;
      (* obligations *)
      test "obligations enumerate paths and kinds"
        obligations_enumerate_paths_and_kinds;
      test "obligations are empty for unconfined and refused seals"
        obligations_are_empty_for_unconfined_and_refused;
      (* admits *)
      test "admits reproduces the host gate" admits_reproduces_the_host_gate;
      (* Evidence codec *)
      test "evidence json shapes" evidence_json_shapes;
      test "evidence cases are pairwise distinct" evidence_cases_are_distinct;
      (* Identity *)
      test "identity domain and framing" identity_domain_and_framing;
      test "identity digests are byte-stable pins" identity_digest_pins;
      test "identity changes on a confinement change"
        identity_changes_on_confinement_change;
      test "identity separates evidence classes" identity_class_separation;
      test "identity jsont round-trips preserving the digest"
        identity_jsont_round_trips;
      test "identity decode rejects non-canonical states"
        identity_decode_rejects_non_canonical;
    ]
