(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

type t = { bindings : string array; path_dirs : string list }

module Policy = struct
  type t = {
    inherit_all : bool;
    exclude : string list;
    include_only : string list;
  }

  let default = { inherit_all = false; exclude = []; include_only = [] }
end

(* Nothing in the child environment is rewritten. [HOME], the temp-dir family
   and the three base directories the resolver reads are inherited like every
   other allow-listed name, so the resolver derives its roots from the same
   values the child reads and the two cannot disagree — which is the whole of
   the bug class this replaced. A redirect also concealed the absence of the
   grants it stood in for: [/tmp] was ungranted for the life of the product and
   nobody noticed, because nothing ever pointed at it. Inheriting makes a
   missing grant a first-run error instead of a silence.

   The rule that keeps the pair honest is not "inherit [HOME]" but {e inherit
   every variable a root is derived from}. Leave one out and the resolver grants
   the directory the launcher named while the child computes a different one
   from its [$HOME] default — the same disagreement, one variable narrower.
   Inheriting these opens nothing on its own: each is a base the policy still
   has to grant a clause under, and Mentat's own directory beneath one of them
   is denied outright.

   Ambient secrets and agent sockets are still stripped: inheritance is
   allow-listed, which is the part worth keeping. *)
let fixed_bindings =
  [
    ("CLICOLOR", "0");
    ("CLICOLOR_FORCE", "0");
    ("GIT_PAGER", "cat");
    ("LESS", "-FRX");
    ("NO_COLOR", "1");
    ("PAGER", "cat");
    ("TERM", "dumb");
    (* Dune's revision-store memo lives in a directory the policy denies, and
       dune opens it read-write even to read it — with no handler, so a confined
       build aborts with an unmapped LMDB error rather than losing a cache. The
       binding is not a redirect: it points the child at nothing, it tells dune
       the thing the policy already decided, so the two agree instead of
       disagreeing. What is lost is a memo over `git ls-tree`, which dune
       recomputes; what is kept is a store whose contents it serves back as file
       bytes without re-hashing. *)
    ("DUNE_CONFIG__REV_STORE_CACHE", "disabled");
  ]

let inherited_names =
  [
    "HOME";
    "TEMP";
    "TMP";
    "TMPDIR";
    "OPAMROOT";
    "XDG_CACHE_HOME";
    "XDG_CONFIG_HOME";
    (* The two remaining root-derivation variables that are not base
       directories: the resolver reads [GIT_CONFIG_GLOBAL] for the git-config
       admit — git treats a denied read as fatal, and when the variable is set
       it REPLACES both default paths, so a child without it resolves files
       the policy never admitted — and [DUNE_CACHE_ROOT] for the cache grant,
       ahead of the XDG base, exactly as dune does. Both sit here rather than
       in a governable set for the same reason [HOME] does: the policy grants
       what the child computes, and no configuration may split the pair. *)
    "GIT_CONFIG_GLOBAL";
    "DUNE_CACHE_ROOT";
    "LANG";
    "LANGUAGE";
    "LC_ALL";
    "LC_COLLATE";
    "LC_CTYPE";
    "LC_MESSAGES";
    "LC_MONETARY";
    "LC_NUMERIC";
    "LC_TIME";
  ]

let single_toolchain_paths =
  [
    "DUNE_OCAML_STDLIB"; "OCAMLLIB"; "OCAML_TOPLEVEL_PATH"; "OPAM_SWITCH_PREFIX";
  ]

let toolchain_path_lists = [ "CAML_LD_LIBRARY_PATH"; "OCAMLPATH" ]

(* Build tools read more configuration from the environment than the OCaml
   family alone: the C toolchain that compiles every foreign stub ([CC] and
   the flag families), pkg-config's search path — what a [conf-*] package
   probes the system through — the proxy and TLS-trust variables without
   which a fetch behind a corporate network is dead (the lowercase proxy
   spellings are the ones curl actually reads), and git's identity, which
   decides what a commit is authored as. Each is configuration a confined
   command must read exactly as the user's shell would — a stripped proxy is
   a failed [dune pkg] fetch, a stripped [CC] a differently built stub — and
   none carries a credential by convention. Inherited verbatim. *)
let build_tool_names =
  [
    "CC";
    "CXX";
    "CPPFLAGS";
    "CFLAGS";
    "CXXFLAGS";
    "LDFLAGS";
    "PKG_CONFIG";
    "PKG_CONFIG_PATH";
    "PKG_CONFIG_LIBDIR";
    "HTTP_PROXY";
    "HTTPS_PROXY";
    "FTP_PROXY";
    "ALL_PROXY";
    "NO_PROXY";
    "http_proxy";
    "https_proxy";
    "ftp_proxy";
    "all_proxy";
    "no_proxy";
    "SSL_CERT_FILE";
    "SSL_CERT_DIR";
    "CURL_CA_BUNDLE";
    "GIT_AUTHOR_NAME";
    "GIT_AUTHOR_EMAIL";
    "GIT_COMMITTER_NAME";
    "GIT_COMMITTER_EMAIL";
    "EMAIL";
  ]

(* Dune and the OCaml toolchain take their configuration from the environment
   as much as from files: the shared-cache mode and root, the build profile,
   the sandboxing mode, the job count, every [DUNE_CONFIG__*] override,
   [OCAMLPARAM]. Dune folds several of these into the digest of every rule it
   runs, so a confined build that sees a different configuration from the
   user's shell does not merely behave differently: it re-executes the world,
   and the user's next build re-executes it back, each side invalidating the
   other's build directory for as long as the two disagree. The families are
   inherited whole, by prefix, so the build inside is configured exactly like
   the build outside. A member that names a directory is a base the policy
   still has to grant — the resolver reads [DUNE_CACHE_ROOT] the way dune does
   — and a member the toolchain lists above already own keeps its normalized
   treatment, dropped included: the family must not hand back verbatim what
   normalization refused.

   The names dune assigns to the actions it spawns are not configuration but
   handles on that running instance — its trace directory, a cram test's
   source root, the site locations of a built executable — and stay stripped
   the way agent sockets do: a Mentat launched from inside a dune action must
   not hand its children another dune's session. *)
let configuration_prefixes = [ "DUNE_"; "OCAML"; "CAML" ]

let dune_action_handles =
  [ "DUNE_ACTION_TRACE_DIR"; "DUNE_SOURCEROOT"; "DUNE_DIR_LOCATIONS" ]

let configuration_family name =
  List.exists
    (fun prefix -> String.starts_with ~prefix name)
    configuration_prefixes
  && not (List.mem name dune_action_handles)

(* Case-insensitive glob over ['*'] alone — the vocabulary the policy's
   [exclude] and [include_only] speak, and the floor below. Environment names
   are short, so the naive scan is fine. *)
let glob_matches pattern name =
  let pattern = String.lowercase_ascii pattern in
  let name = String.lowercase_ascii name in
  let find_from haystack ~start needle =
    let h = String.length haystack and n = String.length needle in
    let rec scan i =
      if i + n > h then None
      else if String.equal (String.sub haystack i n) needle then Some i
      else scan (i + 1)
    in
    if start > h then None else scan start
  in
  match String.split_on_char '*' pattern with
  | [] -> assert false (* [split_on_char] never returns [] *)
  | [ exact ] -> String.equal exact name
  | first :: rest ->
      String.starts_with ~prefix:first name
      &&
      let length = String.length name in
      let rec loop position = function
        | [] -> true
        | [ last ] ->
            let tail = length - String.length last in
            tail >= position
            && String.equal last (String.sub name tail (String.length last))
        | segment :: rest -> (
            match find_from name ~start:position segment with
            | None -> false
            | Some found -> loop (found + String.length segment) rest)
      in
      loop (String.length first) rest

(* The floor: names that never reach the child through a family, the curated
   sets, or [inherit_all] — secret-shaped names by convention, and the handles
   that address an agent or a running instance rather than configure a tool.
   The floor is not configuration: [Policy.exclude] adds to it and nothing
   subtracts from it. A pattern list is best-effort by nature — a credential
   living in [DATABASE_URL] does not match — which is why [inherit_all] is an
   explicit posture choice and [include_only] the hard mode, not the default. *)
let floor_patterns =
  [ "*KEY*"; "*SECRET*"; "*TOKEN*"; "*PASSWORD*"; "*PASSWD*"; "*CREDENTIAL*" ]

let floor_names =
  [
    "SSH_AUTH_SOCK";
    "SSH_AGENT_PID";
    "GPG_AGENT_INFO";
    "DBUS_SESSION_BUS_ADDRESS";
    "INSIDE_DUNE";
  ]
  @ dune_action_handles

let floored name =
  List.mem name floor_names
  || String.starts_with ~prefix:"MENTAT_" name
  || List.exists (fun pattern -> glob_matches pattern name) floor_patterns

(* The policy gate over every governable name. The structural set — [PATH],
   the fixed bindings, and the inherited base directories the resolver derives
   roots from — is not governable: excluding [HOME] would leave the policy
   granting directories the child no longer computes, the disagreement this
   library exists to prevent. *)
let admitted (policy : Policy.t) name =
  (not (floored name))
  && (not
        (List.exists
           (fun pattern -> glob_matches pattern name)
           policy.Policy.exclude))
  &&
  match policy.Policy.include_only with
  | [] -> true
  | patterns -> List.exists (fun pattern -> glob_matches pattern name) patterns

(* Normalization drops what cannot be represented rather than failing:
   construction is total, and a bad ambient segment costs only itself. *)
let normalize_path_list value =
  let rec loop seen normalized = function
    | [] -> List.rev normalized
    | segment :: rest -> (
        match Lpath.Abs.of_string segment with
        | Error _ -> loop seen normalized rest
        | Ok path ->
            let spelling = Lpath.Abs.to_string path in
            if List.mem spelling seen then loop seen normalized rest
            else loop (spelling :: seen) (spelling :: normalized) rest)
  in
  loop [] [] (String.split_on_char ':' value)

let normalize_single_path value =
  match Lpath.Abs.of_string value with
  | Ok path -> Some (Lpath.Abs.to_string path)
  | Error _ -> None

let add_inherited ~normalize lookup names bindings =
  List.fold_left
    (fun bindings name ->
      match lookup name with
      | None -> bindings
      | Some value when String.contains value '\000' -> bindings
      | Some value -> (
          match normalize value with
          | None -> bindings
          | Some value -> (name, value) :: bindings))
    bindings names

let make ~path ~lookup ~names ~policy =
  let admitted = admitted policy in
  let governed names = List.filter admitted names in
  let path_dirs = normalize_path_list path in
  let bindings = ("PATH", String.concat ":" path_dirs) :: fixed_bindings in
  let bindings =
    add_inherited ~normalize:Option.some lookup inherited_names bindings
  in
  let bindings =
    add_inherited ~normalize:Option.some lookup
      (governed build_tool_names)
      bindings
  in
  (* The toolchain path variables are root-derivation inputs too — the
     resolver admits read roots and prepends the switch [bin] from them — so
     they are not governable either, only normalized. *)
  let bindings =
    add_inherited ~normalize:normalize_single_path lookup single_toolchain_paths
      bindings
  in
  let bindings =
    add_inherited
      ~normalize:(fun value ->
        match normalize_path_list value with
        | [] -> None
        | dirs -> Some (String.concat ":" dirs))
      lookup toolchain_path_lists bindings
  in
  let owned =
    List.map fst fixed_bindings
    @ inherited_names @ build_tool_names @ single_toolchain_paths
    @ toolchain_path_lists
  in
  let bindings =
    let family =
      List.filter
        (fun name ->
          configuration_family name
          && (not (List.mem name owned))
          && admitted name)
        names
      |> List.sort_uniq String.compare
    in
    add_inherited ~normalize:Option.some lookup family bindings
  in
  (* [inherit_all]: the remaining ambient names, floor and policy permitting.
     A curated name whose value normalization dropped must not re-enter
     verbatim through this pass, so the owned lists are excluded along with
     everything already bound. *)
  let bindings =
    if not policy.Policy.inherit_all then bindings
    else
      let bound = List.map fst bindings in
      let rest =
        List.filter
          (fun name ->
            (not (List.mem name bound))
            && (not (List.mem name owned))
            && (not (String.equal name "PATH"))
            && admitted name)
          names
        |> List.sort_uniq String.compare
      in
      add_inherited ~normalize:Option.some lookup rest bindings
  in
  let bindings =
    List.sort (fun (a, _) (b, _) -> String.compare a b) bindings
    |> List.map (fun (name, value) -> name ^ "=" ^ value)
    |> Array.of_list
  in
  { bindings; path_dirs }
