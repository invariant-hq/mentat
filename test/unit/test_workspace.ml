(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Syntax = Lpath
module Workspace = Mentat_workspace
module Json = Jsont.Json

(* The suite pins the unified workspace path contract: stable identity,
   lexical containment, current binding, root admission roles, strict codecs,
   structured errors, and the ephemeral notice datum. *)

(* Helpers *)

let abs text =
  match Syntax.Abs.of_string text with
  | Ok path -> path
  | Error error -> failf "%s: %a" text Syntax.Error.pp error

let rel text =
  match Syntax.Rel.of_string text with
  | Ok path -> path
  | Error error -> failf "%s: %a" text Syntax.Error.pp error

let make_root text = Workspace.Root.of_dir (abs text)

let make_path root text =
  Workspace.Path.make ~root_key:(Workspace.Root.key root) (rel text)

let abs_string workspace path =
  match Workspace.to_abs workspace path with
  | Ok path -> Syntax.Abs.to_string path
  | Error error -> failf "to_abs: %s" (Workspace.Resolve_error.message error)

let ok_ws = function
  | Ok workspace -> workspace
  | Error error -> failf "make: %s" (Workspace.Error.message error)

let json_encode codec value =
  match Json.encode codec value with
  | Ok json -> json
  | Error message -> failf "encode failed: %s" message

let json_decode codec json =
  match Json.decode codec json with
  | Ok value -> value
  | Error message -> failf "decode failed: %s" message

(* Testables. [ws_error] (not [error]) so the windtrap {!error} result assertion
   stays reachable for the durable [`Unknown_root] check. *)

let syntax_error = Testable.make ~pp:Syntax.Error.pp ~equal:Syntax.Error.equal
let ws_error = Testable.make ~pp:Workspace.Error.pp ~equal:Workspace.Error.equal

let resolve_error =
  Testable.make ~pp:Workspace.Resolve_error.pp
    ~equal:Workspace.Resolve_error.equal

let root_value = Testable.make ~pp:Workspace.Root.pp ~equal:Workspace.Root.equal
let path_value = Testable.make ~pp:Workspace.Path.pp ~equal:Workspace.Path.equal
let rel_value = Testable.make ~pp:Syntax.Rel.pp ~equal:Syntax.Rel.equal
let workspace_value = Testable.make ~pp:Workspace.pp ~equal:Workspace.equal

(* Generators for roots, rels, and paths.

   Root/rel components are drawn from mixed-case letters plus a few safe
   symbols: paths reject NUL, [.], [..], and drive prefixes at construction, so
   those bytes belong to the token generator below, not here. Mixed case is what
   exercises the byte-lexical, case-sensitive root identity. *)

let component_char =
  Gen.frequency
    [
      (5, Gen.char_range 'a' 'z');
      (2, Gen.char_range 'A' 'Z');
      (2, Gen.of_list [ '0'; '9'; '-'; '_' ]);
    ]

let component_gen = Gen.string_of ~size:(Gen.int_range 1 5) component_char

let components_gen min max =
  Gen.list ~size:(Gen.int_range min max) component_gen

let rel_of_components = function
  | [] -> Syntax.Rel.root
  | cs -> rel (String.concat "/" cs)

let root_of_components components =
  make_root ("/" ^ String.concat "/" components)

let path_gen =
  Gen.bind (components_gen 1 3) (fun root_components ->
      Gen.map
        (fun rel_components ->
          Workspace.Path.make
            ~root_key:(Workspace.Root.key (root_of_components root_components))
            (rel_of_components rel_components))
        (components_gen 0 5))

let path_value_gen = Gen.with_pp Workspace.Path.pp path_gen
let small_rel_gen = Gen.map rel_of_components (components_gen 0 3)

(* Path pairs biased to hit equal, same-root descendant, and disjoint, so the
   is_within/relativize agreement property sees both boolean outcomes. *)
let path_pair_gen =
  Gen.one_of
    [
      Gen.map (fun p -> (p, p)) path_gen;
      Gen.bind path_gen (fun base ->
          Gen.map
            (fun suffix -> (base, Workspace.Path.append base suffix))
            small_rel_gen);
      Gen.bind path_gen (fun a -> Gen.map (fun b -> (a, b)) path_gen);
    ]

let path_pair_gen =
  Gen.with_pp
    (fun ppf (a, b) ->
      Format.fprintf ppf "(%a, %a)" Workspace.Path.pp a Workspace.Path.pp b)
    path_pair_gen

let dir_components_gen =
  Gen.with_pp
    (fun ppf cs -> Format.fprintf ppf "[%s]" (String.concat "; " cs))
    (components_gen 1 3)

(* A base root, a nested root strictly below it, and a target below the nested
   root, as both an absolute path and its root-relative suffix. Drives the
   most-specific-root law. *)
type nested_case = {
  base : Workspace.Root.t;
  nested : Workspace.Root.t;
  target_abs : Syntax.Abs.t;
  target_rel : Syntax.Rel.t;
}

let nested_case_gen =
  Gen.bind (components_gen 1 3) (fun base_components ->
      Gen.bind (components_gen 1 2) (fun nested_components ->
          Gen.map
            (fun target_components ->
              let base = root_of_components base_components in
              let nested =
                Workspace.Root.of_dir
                  (Syntax.Abs.append_rel (Workspace.Root.dir base)
                     (rel_of_components nested_components))
              in
              let target_rel = rel_of_components target_components in
              {
                base;
                nested;
                target_abs =
                  Syntax.Abs.append_rel (Workspace.Root.dir nested) target_rel;
                target_rel;
              })
            (components_gen 0 4)))

let nested_case_gen =
  Gen.with_pp
    (fun ppf case ->
      Format.fprintf ppf "{ base = %a; nested = %a; target = %a }"
        Workspace.Root.pp case.base Workspace.Root.pp case.nested Syntax.Abs.pp
        case.target_abs)
    nested_case_gen

(* Root keys are JSON-safe text: non-empty valid UTF-8 without ASCII control
   characters. The property generator covers the printable ASCII subset;
   examples below cover Unicode and each rejection class. *)
let key_char =
  Gen.frequency
    [
      (5, Gen.char_range 'a' 'z');
      (2, Gen.char_range 'A' 'Z');
      (2, Gen.of_list [ '0'; '9'; '-'; '_'; ' '; '/' ]);
    ]

let key_text_gen = Gen.string_of ~size:(Gen.int_range 1 12) key_char

let keyed_path_gen =
  Gen.bind key_text_gen (fun key ->
      Gen.map
        (fun rel_components ->
          Workspace.Path.make
            ~root_key:(Workspace.Root.Key.of_string_exn key)
            (rel_of_components rel_components))
        (components_gen 0 4))

let keyed_path_gen = Gen.with_pp Workspace.Path.pp keyed_path_gen

(* Raw resolver fuzz: empty, dot-soup, deep climbs, and malformed bytes (NUL,
   backslash, drive-ish colon), so resolve_string's total two-case taxonomy is
   exercised without ever raising. *)
let raw_char =
  Gen.frequency
    [
      (5, Gen.char_range 'a' 'z');
      (3, Gen.of_list [ '/'; '.'; '-' ]);
      (1, Gen.of_list [ '\000'; '\\'; ':' ]);
    ]

let raw_input_gen = Gen.string_of ~size:(Gen.int_range 0 12) raw_char

let root_keys =
  group "root keys"
    [
      test "reject empty keys with matching diagnostics" (fun () ->
          let error = Result.get_error (Workspace.Root.Key.of_string "") in
          equal string ~msg:"message and printer agree"
            (Workspace.Root.Key.message error)
            (Format.asprintf "%a" Workspace.Root.Key.pp_error error);
          raises_match ~msg:"trusted constructor rejects empty"
            (function Invalid_argument _ -> true | _ -> false)
            (fun () -> Workspace.Root.Key.of_string_exn ""));
      test "rejects non-UTF-8 and ASCII control characters" (fun () ->
          (match Workspace.Root.Key.of_string "\255" with
          | Error Workspace.Root.Key.Invalid_utf_8 -> ()
          | Error error ->
              failf "wrong non-UTF-8 error: %a" Workspace.Root.Key.pp_error
                error
          | Ok _ -> failf "non-UTF-8 key should be rejected");
          (match Workspace.Root.Key.of_string "line\nbreak" with
          | Error
              (Workspace.Root.Key.Control_character
                 { byte_index = 4; byte = 0x0A }) ->
              ()
          | Error error ->
              failf "wrong control error: %a" Workspace.Root.Key.pp_error error
          | Ok _ -> failf "control-bearing key should be rejected");
          List.iter
            (fun raw ->
              is_true
                ~msg:("reject " ^ String.escaped raw)
                (Result.is_error (Workspace.Root.Key.of_string raw)))
            [ "nul\000byte"; "\127" ];
          equal
            (result
               (Testable.make ~pp:Workspace.Root.Key.pp
                  ~equal:Workspace.Root.Key.equal)
               pass)
            ~msg:"Unicode text is valid"
            (Ok (Workspace.Root.Key.of_string_exn "projet-caf\195\169"))
            (Workspace.Root.Key.of_string "projet-caf\195\169"));
      prop "constructors, equality, ordering, and codec agree" key_text_gen
        (fun name ->
          let key = Workspace.Root.Key.of_string_exn name in
          equal
            (result
               (Testable.make ~pp:Workspace.Root.Key.pp
                  ~equal:Workspace.Root.Key.equal)
               pass)
            ~msg:"parse printed key" (Ok key)
            (Workspace.Root.Key.of_string (Workspace.Root.Key.to_string key));
          equal int ~msg:"compare agrees with equality" 0
            (Workspace.Root.Key.compare key key);
          is_true ~msg:"codec round trip"
            (Workspace.Root.Key.equal key
               (json_decode Workspace.Root.Key.jsont
                  (json_encode Workspace.Root.Key.jsont key))));
      test "keys are case-sensitive" (fun () ->
          is_false ~msg:"case participates in identity"
            (Workspace.Root.Key.equal
               (Workspace.Root.Key.of_string_exn "Project")
               (Workspace.Root.Key.of_string_exn "project")));
    ]

(* Roots *)

let roots =
  group "roots"
    [
      test "of_dir derives a normalized location-bound key" (fun () ->
          equal string ~msg:"normalized" "/workspace/root"
            (Workspace.Root.Key.to_string
               (Workspace.Root.key (make_root "/workspace/./root"))));
      test "of_dir safely encodes bytes that root keys cannot contain"
        (fun () ->
          let key text =
            Workspace.Root.of_dir (abs text)
            |> Workspace.Root.key |> Workspace.Root.Key.to_string
          in
          equal string ~msg:"space" "/workspace/a%20b" (key "/workspace/a b");
          equal string ~msg:"percent" "/workspace/a%25b" (key "/workspace/a%b");
          equal string ~msg:"control" "/workspace/a%0Ab" (key "/workspace/a\nb");
          equal string ~msg:"non-UTF-8 byte" "/workspace/%FF"
            (key "/workspace/\255"));
      test "equal compares key and directory; same_key compares identity alone"
        (fun () ->
          let normalized = make_root "/workspace/./root" in
          let plain = make_root "/workspace/root" in
          let keyed =
            Workspace.Root.make
              ~key:(Workspace.Root.Key.of_string_exn "shared")
              (abs "/tmp/root")
          in
          let same_key_other_dir =
            Workspace.Root.make
              ~key:(Workspace.Root.Key.of_string_exn "shared")
              (abs "/other/root")
          in
          is_true ~msg:"normalization keeps roots equal"
            (Workspace.Root.equal normalized plain);
          equal int ~msg:"compare agrees with equal" 0
            (Workspace.Root.compare normalized plain);
          is_true ~msg:"same_key ignores the directory"
            (Workspace.Root.same_key keyed same_key_other_dir);
          is_false ~msg:"same key, different dir is not equal"
            (Workspace.Root.equal keyed same_key_other_dir);
          is_false ~msg:"distinct roots are distinct"
            (Workspace.Root.equal normalized (make_root "/workspace/other")));
      test "identity is byte-lexical and case-sensitive" (fun () ->
          is_false ~msg:"casing distinguishes directories"
            (Workspace.Root.equal (make_root "/Workspace")
               (make_root "/workspace"));
          is_false ~msg:"casing distinguishes keys"
            (Workspace.Root.same_key (make_root "/A/b") (make_root "/a/b")));
      test "two casings are admitted as two distinct roots" (fun () ->
          let upper = make_root "/Ws" and lower = make_root "/ws" in
          let workspace =
            ok_ws (Workspace.make ~primary:upper ~read_only:[ lower ] ())
          in
          equal (list root_value) ~msg:"both admitted" [ upper; lower ]
            (Workspace.roots workspace));
      prop "root identity tracks the directory bytes"
        (Gen.pair dir_components_gen dir_components_gen) (fun (a, b) ->
          let ra = root_of_components a and rb = root_of_components b in
          let same_dir =
            Syntax.Abs.equal (Workspace.Root.dir ra) (Workspace.Root.dir rb)
          in
          equal bool ~msg:"equal iff same directory" same_dir
            (Workspace.Root.equal ra rb);
          equal bool ~msg:"same_key iff same directory (path-derived key)"
            same_dir
            (Workspace.Root.same_key ra rb));
    ]

(* Addresses: the Path waist (lexical projection) *)

let addresses =
  group "addresses"
    [
      test "projects, decomposes, and composes" (fun () ->
          let root = make_root "/workspace" in
          let workspace = Workspace.single root in
          let root_path = make_path root "." in
          let file = make_path root "src/a.ml" in
          equal string ~msg:"root key accessor"
            (Workspace.Root.Key.to_string (Workspace.Root.key root))
            (Workspace.Root.Key.to_string (Workspace.Path.root_key file));
          equal string ~msg:"relative accessor" "src/a.ml"
            (Syntax.Rel.to_string (Workspace.Path.rel file));
          equal string ~msg:"workspace-owned absolute binding"
            "/workspace/src/a.ml"
            (abs_string workspace file);
          is_true ~msg:"root path recognized" (Workspace.Path.is_root root_path);
          is_false ~msg:"file is not a root path" (Workspace.Path.is_root file);
          equal path_value ~msg:"root_of projects a path onto its root path"
            root_path
            (Workspace.Path.root_of file);
          equal (option string) ~msg:"root path has no basename" None
            (Workspace.Path.basename root_path);
          equal (option string) ~msg:"basename" (Some "a.ml")
            (Workspace.Path.basename file);
          equal (option path_value) ~msg:"root path has no parent" None
            (Workspace.Path.parent root_path);
          equal (option string) ~msg:"parent" (Some "src")
            (Option.map Workspace.Path.display (Workspace.Path.parent file));
          equal string ~msg:"display is root-relative" "src/a.ml"
            (Workspace.Path.display file);
          equal string ~msg:"root display is dot" "."
            (Workspace.Path.display root_path);
          equal string ~msg:"binding remains explicit" "/workspace/src/a.ml"
            (abs_string workspace file));
      test "add_component appends one component or rejects a separator"
        (fun () ->
          let root = make_root "/workspace" in
          equal
            (result string syntax_error)
            ~msg:"appends one component" (Ok "src/a.ml")
            (Result.map Workspace.Path.display
               (Workspace.Path.add_component (make_path root "src") "a.ml"));
          equal
            (result string syntax_error)
            ~msg:"rejects a malformed component"
            (Error (Syntax.Error.Malformed_component "a/b"))
            (Result.map Workspace.Path.display
               (Workspace.Path.add_component (make_path root ".") "a/b")));
      test "append preserves the root; relativize is root-scoped" (fun () ->
          let root = make_root "/workspace" in
          let other = make_root "/other" in
          let file = make_path root "src/a.ml" in
          equal path_value ~msg:"append below a path"
            (make_path root "src/lib/a.ml")
            (Workspace.Path.append (make_path root "src") (rel "lib/a.ml"));
          equal (option rel_value) ~msg:"relativize returns the suffix"
            (Some (rel "a.ml"))
            (Workspace.Path.relativize ~root:(make_path root "src") file);
          equal (option rel_value) ~msg:"relativize across roots is None" None
            (Workspace.Path.relativize ~root:(make_path other ".") file));
      test "equality and collections normalize the relative path" (fun () ->
          let root = make_root "/workspace" in
          let a = make_path root "src/./a.ml" in
          let b = make_path root "src/a.ml" in
          is_true ~msg:"equal on root and normalized rel"
            (Workspace.Path.equal a b);
          equal int ~msg:"compare agrees with equal" 0
            (Workspace.Path.compare a b);
          is_true ~msg:"set membership uses path equality"
            (Workspace.Path.Set.mem b (Workspace.Path.Set.singleton a));
          equal (option string) ~msg:"map lookup uses path equality"
            (Some "file")
            (Workspace.Path.Map.find_opt b
               (Workspace.Path.Map.singleton a "file")));
      prop "is_within agrees with relativize (decision ii)" path_pair_gen
        (fun (root, p) ->
          let within = Option.is_some (Workspace.Path.relativize ~root p) in
          cover "within" within;
          cover "disjoint" (not within);
          equal bool ~msg:"is_within = is_some relativize" within
            (Workspace.Path.is_within ~root p));
    ]

(* The address space: construction, bijection, admission partition *)

let workspace =
  group "workspace"
    [
      test "make admits primary then auxiliaries, dropping exact duplicates"
        (fun () ->
          let primary = make_root "/workspace" in
          let duplicate = make_root "/workspace/." in
          let vendor = make_root "/workspace/vendor" in
          let workspace =
            ok_ws
              (Workspace.make ~primary
                 ~read_only:[ duplicate; vendor; vendor ]
                 ())
          in
          equal (list root_value) ~msg:"deduplicated, primary first"
            [ primary; vendor ]
            (Workspace.roots workspace));
      test "make rejects a key naming two directories" (fun () ->
          let primary = make_root "/workspace" in
          let conflict =
            Workspace.Root.make
              ~key:(Workspace.Root.key primary)
              (abs "/elsewhere")
          in
          equal
            (result workspace_value ws_error)
            ~msg:"one key, two dirs"
            (Error
               (Workspace.Error.Conflicting_root
                  { existing = primary; duplicate = conflict }))
            (Workspace.make ~primary ~read_only:[ conflict ] ()));
      test "make rejects a directory admitted under two keys" (fun () ->
          let primary = make_root "/workspace" in
          let conflict =
            Workspace.Root.make
              ~key:(Workspace.Root.Key.of_string_exn "other")
              (Workspace.Root.dir primary)
          in
          equal
            (result workspace_value ws_error)
            ~msg:"one dir, two keys"
            (Error
               (Workspace.Error.Conflicting_root
                  { existing = primary; duplicate = conflict }))
            (Workspace.make ~primary ~read_only:[ conflict ] ()));
      test "make detects a conflict between two auxiliaries" (fun () ->
          let primary = make_root "/workspace" in
          let vendor = make_root "/vendor" in
          let vendor_alias =
            Workspace.Root.make
              ~key:(Workspace.Root.key vendor)
              (abs "/vendor-mirror")
          in
          equal
            (result workspace_value ws_error)
            ~msg:"aux vs aux"
            (Error
               (Workspace.Error.Conflicting_root
                  { existing = vendor; duplicate = vendor_alias }))
            (Workspace.make ~primary ~read_only:[ vendor; vendor_alias ] ()));
      test "cwd defaults to the primary and must belong to an admitted root"
        (fun () ->
          let primary = make_root "/workspace" in
          let vendor = make_root "/workspace/vendor" in
          let outside = make_root "/outside" in
          let workspace =
            ok_ws (Workspace.make ~primary ~read_only:[ vendor ] ())
          in
          equal path_value ~msg:"default cwd is the primary root"
            (make_path primary ".") (Workspace.cwd workspace);
          equal
            (result workspace_value ws_error)
            ~msg:"a cwd outside the workspace is rejected"
            (Error
               (Workspace.Error.Root_not_in_workspace
                  (Workspace.Root.key outside)))
            (Workspace.make ~cwd:(make_path outside ".") ~primary
               ~read_only:[ vendor ] ()));
      test "accessors expose the admission partition" (fun () ->
          let primary = make_root "/workspace" in
          let vendor = make_root "/vendor" in
          let docs = make_root "/docs" in
          let workspace =
            ok_ws (Workspace.make ~primary ~read_only:[ vendor; docs ] ())
          in
          equal root_value ~msg:"primary" primary (Workspace.primary workspace);
          equal (list root_value) ~msg:"read-only in admission order"
            [ vendor; docs ]
            (Workspace.read_only_roots workspace);
          equal (list root_value) ~msg:"roots, primary first"
            [ primary; vendor; docs ]
            (Workspace.roots workspace);
          is_true ~msg:"primary is writable"
            (Workspace.is_writable workspace primary);
          is_false ~msg:"an auxiliary is read-only"
            (Workspace.is_writable workspace vendor);
          is_false ~msg:"an unadmitted root is not writable"
            (Workspace.is_writable workspace (make_root "/other"));
          equal (option root_value) ~msg:"root_by_key rebinds an admitted key"
            (Some vendor)
            (Workspace.root_by_key workspace (Workspace.Root.key vendor));
          equal (option pass) ~msg:"root_by_key on an unknown key is None" None
            (Workspace.root_by_key workspace
               (Workspace.Root.Key.of_string_exn "absent")));
      test "root_path is the primary, independent of cwd" (fun () ->
          let primary = make_root "/workspace" in
          let vendor = make_root "/workspace/vendor" in
          let workspace =
            ok_ws
              (Workspace.make ~cwd:(make_path vendor "src") ~primary
                 ~read_only:[ vendor ] ())
          in
          equal path_value ~msg:"root_path stays at the primary"
            (make_path primary ".")
            (Workspace.root_path workspace);
          equal path_value ~msg:"path_at_cwd_root builds below the cwd's root"
            (make_path vendor "app/main.ml")
            (Workspace.path_at_cwd_root workspace (rel "app/main.ml")));
      test "single is a one-root primary workspace" (fun () ->
          let primary = make_root "/workspace" in
          let workspace = Workspace.single primary in
          equal (list root_value) ~msg:"only the primary" [ primary ]
            (Workspace.roots workspace);
          equal (list root_value) ~msg:"no auxiliaries" []
            (Workspace.read_only_roots workspace);
          equal path_value ~msg:"cwd defaults to the root"
            (make_path primary ".") (Workspace.cwd workspace);
          is_true ~msg:"the single root is writable"
            (Workspace.is_writable workspace primary);
          let recwd = Workspace.single ~cwd:(rel "app") primary in
          equal string ~msg:"single ~cwd is root-relative" "/workspace/app"
            (abs_string recwd (Workspace.cwd recwd)));
      test "contains_path checks admission" (fun () ->
          let primary = make_root "/workspace" in
          let outside = make_root "/outside" in
          let workspace = Workspace.single primary in
          is_true ~msg:"an admitted root is contained"
            (Workspace.contains_path workspace (make_path primary "src/a.ml"));
          is_false ~msg:"an unadmitted root is not contained"
            (Workspace.contains_path workspace (make_path outside "src/a.ml")));
      test "equality is sensitive to root order, primary, and cwd" (fun () ->
          let a = make_root "/a"
          and b = make_root "/b"
          and c = make_root "/c" in
          let w = ok_ws (Workspace.make ~primary:a ~read_only:[ b; c ] ()) in
          let w_again =
            ok_ws (Workspace.make ~primary:a ~read_only:[ b; c ] ())
          in
          let w_reordered =
            ok_ws (Workspace.make ~primary:a ~read_only:[ c; b ] ())
          in
          let w_reprimaried =
            ok_ws (Workspace.make ~primary:b ~read_only:[ a; c ] ())
          in
          let w_recwd =
            ok_ws
              (Workspace.make ~cwd:(make_path b ".") ~primary:a
                 ~read_only:[ b; c ] ())
          in
          is_true ~msg:"structural equality" (Workspace.equal w w_again);
          is_false ~msg:"auxiliary order participates"
            (Workspace.equal w w_reordered);
          is_false ~msg:"the primary participates"
            (Workspace.equal w w_reprimaried);
          is_false ~msg:"cwd participates" (Workspace.equal w w_recwd));
      prop "duplicate roots are canonicalized to the admitted set"
        nested_case_gen (fun case ->
          let workspace =
            ok_ws
              (Workspace.make ~primary:case.base
                 ~read_only:[ case.nested; case.base; case.nested ]
                 ())
          in
          equal (list root_value) ~msg:"generated duplicates removed"
            [ case.base; case.nested ]
            (Workspace.roots workspace));
    ]

(* Resolution: import_abs, resolve_string, and the two-case taxonomy *)

let resolution =
  group "resolution"
    [
      test "equivalent cwd addresses resolve the same relative input" (fun () ->
          let outer = make_root "/workspace" in
          let nested = make_root "/workspace/vendor" in
          let cwd_outer = make_path outer "vendor" in
          let cwd_nested = make_path nested "." in
          let outer_workspace =
            ok_ws
              (Workspace.make ~cwd:cwd_outer ~primary:outer
                 ~read_only:[ nested ] ())
          in
          let nested_workspace =
            ok_ws
              (Workspace.make ~cwd:cwd_nested ~primary:outer
                 ~read_only:[ nested ] ())
          in
          equal
            (result path_value resolve_error)
            ~msg:"logical cwd, not its root representation, controls resolution"
            (Workspace.resolve_string outer_workspace "../README.md")
            (Workspace.resolve_string nested_workspace "../README.md"));
      test "import_abs chooses the most specific admitted root" (fun () ->
          let root = make_root "/workspace" in
          let nested = make_root "/workspace/vendor" in
          let workspace =
            ok_ws (Workspace.make ~primary:root ~read_only:[ nested ] ())
          in
          equal
            (result path_value resolve_error)
            ~msg:"a nested target picks the nested root"
            (Ok (make_path nested "pkg/a.ml"))
            (Workspace.import_abs workspace (abs "/workspace/vendor/pkg/a.ml"));
          equal
            (result path_value resolve_error)
            ~msg:"the root directory itself imports at rel root"
            (Ok (make_path root "."))
            (Workspace.import_abs workspace (abs "/workspace"));
          equal
            (result path_value resolve_error)
            ~msg:"a sibling prefix is outside, not contained"
            (Error
               (Workspace.Resolve_error.Outside_workspace
                  (abs "/workspace2/a.ml")))
            (Workspace.import_abs workspace (abs "/workspace2/a.ml"));
          equal
            (result path_value resolve_error)
            ~msg:"a path under no root is outside"
            (Error (Workspace.Resolve_error.Outside_workspace (abs "/tmp/a.ml")))
            (Workspace.import_abs workspace (abs "/tmp/a.ml")));
      test "resolve_string resolves relative input against cwd" (fun () ->
          let root = make_root "/workspace" in
          let nested = make_root "/workspace/vendor" in
          let workspace =
            ok_ws
              (Workspace.make ~cwd:(make_path root "src/lib") ~primary:root
                 ~read_only:[ nested ] ())
          in
          equal
            (result path_value resolve_error)
            ~msg:"relative climbs against the cwd"
            (Ok (make_path root "src/test/a.ml"))
            (Workspace.resolve_string workspace "../test/a.ml");
          equal
            (result path_value resolve_error)
            ~msg:"relative into a nested root is canonicalized to it"
            (Ok (make_path nested "pkg.ml"))
            (Workspace.resolve_string workspace "../../vendor/pkg.ml");
          equal
            (result path_value resolve_error)
            ~msg:"relative and absolute agree on the root"
            (Workspace.resolve_string workspace "/workspace/vendor/pkg.ml")
            (Workspace.resolve_string workspace "../../vendor/pkg.ml"));
      test "resolve_string error taxonomy is exactly two cases" (fun () ->
          let root = make_root "/workspace" in
          let workspace =
            ok_ws
              (Workspace.make ~cwd:(make_path root "src/lib") ~primary:root
                 ~read_only:[] ())
          in
          (* Invalid_input: syntax fails before resolution. *)
          equal
            (result path_value resolve_error)
            ~msg:"a malformed component is Invalid_input"
            (Error
               (Workspace.Resolve_error.Invalid_input
                  (Syntax.Error.Malformed_component "a\000b")))
            (Workspace.resolve_string workspace "a\000b");
          equal
            (result path_value resolve_error)
            ~msg:"a backslash fragment is Invalid_input"
            (Error (Workspace.Resolve_error.Invalid_input Syntax.Error.Absolute))
            (Workspace.resolve_string workspace "\\etc");
          equal
            (result path_value resolve_error)
            ~msg:"the empty string is Invalid_input"
            (Error (Workspace.Resolve_error.Invalid_input Syntax.Error.Empty))
            (Workspace.resolve_string workspace "");
          (* Outside_workspace: well-formed, but outside every root. *)
          equal
            (result path_value resolve_error)
            ~msg:"a well-formed absolute outside every root"
            (Error
               (Workspace.Resolve_error.Outside_workspace (abs "/outside/a.ml")))
            (Workspace.resolve_string workspace "/outside/a.ml");
          equal
            (result path_value resolve_error)
            ~msg:"a relative that climbs out of the workspace"
            (Error
               (Workspace.Resolve_error.Outside_workspace (abs "/escape.ml")))
            (Workspace.resolve_string workspace "../../../escape.ml"));
      prop "import_abs of (root_dir / rel) round-trips to the nested root"
        nested_case_gen (fun case ->
          let workspace =
            ok_ws
              (Workspace.make ~primary:case.base ~read_only:[ case.nested ] ())
          in
          equal
            (result path_value resolve_error)
            ~msg:"most specific generated root wins"
            (Ok
               (Workspace.Path.make
                  ~root_key:(Workspace.Root.key case.nested)
                  case.target_rel))
            (Workspace.import_abs workspace case.target_abs);
          (* A sibling sharing a string prefix is outside, not contained. *)
          let sibling =
            abs
              (Syntax.Abs.to_string (Workspace.Root.dir case.base)
              ^ "-sibling/generated.ml")
          in
          equal
            (result path_value resolve_error)
            ~msg:"a sibling string-prefix is Outside_workspace"
            (Error (Workspace.Resolve_error.Outside_workspace sibling))
            (Workspace.import_abs workspace sibling));
      prop "import_abs round-trips a path through the workspace binding"
        path_value_gen (fun path ->
          let key = Workspace.Path.root_key path in
          let root =
            Workspace.Root.make ~key (abs (Workspace.Root.Key.to_string key))
          in
          let workspace = Workspace.single root in
          let projected =
            match Workspace.to_abs workspace path with
            | Ok path -> path
            | Error error ->
                failf "to_abs: %s" (Workspace.Resolve_error.message error)
          in
          equal
            (result path_value resolve_error)
            ~msg:"bound path re-imports to itself" (Ok path)
            (Workspace.import_abs workspace projected));
      prop "resolve_string is total: it never raises and Ok is contained"
        raw_input_gen (fun input ->
          let workspace = Workspace.single (make_root "/workspace") in
          match Workspace.resolve_string workspace input with
          | Error _ -> ()
          | Ok path ->
              is_true
                ~msg:("Ok path is contained: " ^ String.escaped input)
                (Workspace.contains_path workspace path));
    ]

(* Stable identities and current bindings *)

let bindings =
  group "bindings"
    [
      test "one path identity rebinds after workspace relocation" (fun () ->
          let key = Workspace.Root.Key.of_string_exn "project" in
          let original = Workspace.Root.make ~key (abs "/old/project") in
          let relocated = Workspace.Root.make ~key (abs "/new/project") in
          let path = make_path original "src/a.ml" in
          equal string ~msg:"original binding" "/old/project/src/a.ml"
            (abs_string (Workspace.single original) path);
          equal string ~msg:"relocated binding" "/new/project/src/a.ml"
            (abs_string (Workspace.single relocated) path));
      test "to_abs rejects an unadmitted root with the exact key" (fun () ->
          let workspace = Workspace.single (make_root "/workspace") in
          let foreign_key = Workspace.Root.Key.of_string_exn "not-admitted" in
          let path = Workspace.Path.make ~root_key:foreign_key (rel "a.ml") in
          equal
            (result pass resolve_error)
            ~msg:"carries the exact foreign key"
            (Error (Workspace.Resolve_error.Unknown_root foreign_key))
            (Workspace.to_abs workspace path));
      test "writability is an admission role, not path representation"
        (fun () ->
          let primary = make_root "/workspace" in
          let auxiliary = make_root "/vendor" in
          let workspace =
            ok_ws (Workspace.make ~primary ~read_only:[ auxiliary ] ())
          in
          is_true ~msg:"primary path is writable"
            (Workspace.is_writable_path workspace
               (make_path primary "src/a.ml"));
          is_false ~msg:"auxiliary path is read-only"
            (Workspace.is_writable_path workspace
               (make_path auxiliary "src/a.ml"));
          is_false ~msg:"foreign path is not writable"
            (Workspace.is_writable_path workspace
               (make_path (make_root "/foreign") "src/a.ml")));
      test "path equality and order key on root identity and relative path"
        (fun () ->
          let path key relative =
            Workspace.Path.make
              ~root_key:(Workspace.Root.Key.of_string_exn key)
              (rel relative)
          in
          is_true ~msg:"reflexive"
            (Workspace.Path.equal (path "k" "a") (path "k" "a"));
          is_false ~msg:"different key"
            (Workspace.Path.equal (path "k" "a") (path "j" "a"));
          is_false ~msg:"different rel"
            (Workspace.Path.equal (path "k" "a") (path "k" "b"));
          equal int ~msg:"compare agrees with equal" 0
            (Workspace.Path.compare (path "k" "a") (path "k" "a"));
          is_true ~msg:"distinct paths order"
            (Workspace.Path.compare (path "k" "a") (path "k" "b") <> 0));
    ]

(* The stable Path wire *)

let path_object name rel_str =
  Json.object'
    [
      Json.mem (Json.name "root") (Json.string name);
      Json.mem (Json.name "rel") (Json.string rel_str);
    ]

let path_rejections =
  [
    ("not an object (number)", Json.int 1);
    ("not an object (string)", Json.string "x");
    ( "missing rel",
      Json.object' [ Json.mem (Json.name "root") (Json.string "k") ] );
    ( "missing root",
      Json.object' [ Json.mem (Json.name "rel") (Json.string "a") ] );
    ( "unknown field",
      Json.object'
        [
          Json.mem (Json.name "root") (Json.string "k");
          Json.mem (Json.name "rel") (Json.string "a");
          Json.mem (Json.name "extra") (Json.int 1);
        ] );
    ("empty root key", path_object "" "a");
    ("non-UTF-8 root key", path_object "\255" "a");
    ("control in root key", path_object "bad\nkey" "a");
    ("absolute rel", path_object "k" "/x");
    ("escaping rel", path_object "k" "../x");
    ( "root wrong type",
      Json.object'
        [
          Json.mem (Json.name "root") (Json.int 1);
          Json.mem (Json.name "rel") (Json.string "a");
        ] );
    ( "rel wrong type",
      Json.object'
        [
          Json.mem (Json.name "root") (Json.string "k");
          Json.mem (Json.name "rel") (Json.int 1);
        ] );
  ]

let path_wire =
  group "path wire"
    [
      test "encodes the documented { root; rel } object" (fun () ->
          let path =
            Workspace.Path.make
              ~root_key:(Workspace.Root.Key.of_string_exn "the-key")
              (rel "src/a.ml")
          in
          is_true ~msg:"wire shape"
            (Json.equal
               (path_object "the-key" "src/a.ml")
               (json_encode Workspace.Path.jsont path));
          equal (result path_value pass) ~msg:"decode inverts encode" (Ok path)
            (Json.decode Workspace.Path.jsont
               (path_object "the-key" "src/a.ml")));
      prop "round-trips through jsont" keyed_path_gen (fun path ->
          equal path_value path
            (json_decode Workspace.Path.jsont
               (json_encode Workspace.Path.jsont path)));
      cases "decode fails closed" ~name:fst path_rejections (fun (_, json) ->
          is_true (Result.is_error (Json.decode Workspace.Path.jsont json)));
    ]

(* Notices: the workspace prelude datum. Pure data owned here;
   the jsont codec serves the ephemeral wire lane only — notices are never
   journaled. *)

let notice_value =
  Testable.make ~pp:Workspace.Notice.pp ~equal:Workspace.Notice.equal

(* Notice text is otherwise unconstrained producer prose — the generator mixes
   letters with separators and newlines so bodies exercise multi-line text on
   the wire — but never empty, per the constructor invariant. *)
let notice_text_gen =
  Gen.string_of ~size:(Gen.int_range 1 12)
    (Gen.frequency
       [
         (8, Gen.char_range 'a' 'z');
         (2, Gen.of_list [ ' '; '\n'; ':'; '/'; '.' ]);
       ])

let notice_gen =
  Gen.bind
    (Gen.of_list
       [
         Workspace.Notice.Severity.Info;
         Workspace.Notice.Severity.Warning;
         Workspace.Notice.Severity.Error;
       ])
    (fun severity ->
      Gen.bind notice_text_gen (fun source ->
          Gen.bind notice_text_gen (fun title ->
              Gen.bind
                (Gen.one_of
                   [ Gen.map Option.some notice_text_gen; Gen.of_list [ None ] ])
                (fun body ->
                  Gen.map
                    (fun key ->
                      Workspace.Notice.make ~source ~severity ~title ?body ~key
                        ())
                    notice_text_gen))))

let notice_case_gen = Gen.with_pp Workspace.Notice.pp notice_gen

let notice_json mems =
  Json.object' (List.map (fun (name, v) -> Json.mem (Json.name name) v) mems)

(* The documented wire object, in encoding order; [body] is omitted, never
   null, when absent. *)
let notice_object ?body () =
  notice_json
    (List.concat
       [
         [
           ("source", Json.string "dune");
           ("severity", Json.string "warning");
           ("title", Json.string "build broken");
         ];
         (match body with
         | None -> []
         | Some body -> [ ("body", Json.string body) ]);
         [ ("key", Json.string "dune:health") ];
       ])

let notice_rejections =
  let base ?(source = Some (Json.string "dune"))
      ?(severity = Some (Json.string "info")) ?(title = Some (Json.string "t"))
      ?body ?(key = Some (Json.string "k")) ?(extra = []) () =
    notice_json
      (List.filter_map
         (fun (name, v) -> Option.map (fun v -> (name, v)) v)
         [
           ("source", source);
           ("severity", severity);
           ("title", title);
           ("body", body);
           ("key", key);
         ]
      @ extra)
  in
  [
    ("not an object (number)", Json.int 1);
    ("not an object (string)", Json.string "x");
    ("missing source", base ~source:None ());
    ("missing severity", base ~severity:None ());
    ("missing title", base ~title:None ());
    ("missing key", base ~key:None ());
    ("unknown member", base ~extra:[ ("extra", Json.int 1) ] ());
    ("unknown severity", base ~severity:(Some (Json.string "fatal")) ());
    ("severity wrong type", base ~severity:(Some (Json.int 1)) ());
    ("body wrong type", base ~body:(Json.int 1) ());
    ("null body", base ~body:(Json.null ()) ());
    ("empty source", base ~source:(Some (Json.string "")) ());
    ("empty title", base ~title:(Some (Json.string "")) ());
    ("empty key", base ~key:(Some (Json.string "")) ());
    ("empty body", base ~body:(Json.string "") ());
  ]

let notices =
  group "notices"
    [
      test "a notice carries its fields and coalescing key" (fun () ->
          let full =
            Workspace.Notice.make ~source:"dune"
              ~severity:Workspace.Notice.Severity.Warning ~title:"build broken"
              ~body:"3 errors in lib/foo" ~key:"dune:health" ()
          in
          equal string ~msg:"source names the producer" "dune"
            (Workspace.Notice.source full);
          is_true ~msg:"severity round-trips"
            (Workspace.Notice.Severity.equal
               (Workspace.Notice.severity full)
               Workspace.Notice.Severity.Warning);
          equal string ~msg:"title round-trips" "build broken"
            (Workspace.Notice.title full);
          equal (option string) ~msg:"body round-trips"
            (Some "3 errors in lib/foo")
            (Workspace.Notice.body full);
          equal string ~msg:"key round-trips" "dune:health"
            (Workspace.Notice.key full);
          let bare =
            Workspace.Notice.make ~source:"dune"
              ~severity:Workspace.Notice.Severity.Info ~title:"build fixed"
              ~key:"dune:health" ()
          in
          equal (option string) ~msg:"an omitted body is None" None
            (Workspace.Notice.body bare);
          equal string
            ~msg:
              "two notices for the same producer state share the coalescing \
               key whatever their text"
            (Workspace.Notice.key full)
            (Workspace.Notice.key bare));
      test "make rejects empty required text and an empty present body"
        (fun () ->
          let make ?(source = "dune") ?(title = "t") ?body ?(key = "k") () =
            Workspace.Notice.make ~source
              ~severity:Workspace.Notice.Severity.Info ~title ?body ~key ()
          in
          raises ~msg:"empty source"
            (Invalid_argument "Mentat_workspace.Notice.make: source is empty")
            (fun () -> make ~source:"" ());
          raises ~msg:"empty title"
            (Invalid_argument "Mentat_workspace.Notice.make: title is empty")
            (fun () -> make ~title:"" ());
          raises ~msg:"empty key"
            (Invalid_argument "Mentat_workspace.Notice.make: key is empty")
            (fun () -> make ~key:"" ());
          raises ~msg:"empty present body"
            (Invalid_argument "Mentat_workspace.Notice.make: body is empty")
            (fun () -> make ~body:"" ());
          equal (option string) ~msg:"an absent body stays valid" None
            (Workspace.Notice.body (make ())));
      test "equality covers every field; pp renders diagnostics" (fun () ->
          let make ?body ?(severity = Workspace.Notice.Severity.Info)
              ?(title = "t") ?(key = "k") () =
            Workspace.Notice.make ~source:"dune" ~severity ~title ?body ~key ()
          in
          is_true ~msg:"structural equality"
            (Workspace.Notice.equal (make ~body:"b" ()) (make ~body:"b" ()));
          is_false ~msg:"severity participates"
            (Workspace.Notice.equal (make ())
               (make ~severity:Workspace.Notice.Severity.Error ()));
          is_false ~msg:"title participates"
            (Workspace.Notice.equal (make ()) (make ~title:"other" ()));
          is_false ~msg:"body participates"
            (Workspace.Notice.equal (make ()) (make ~body:"b" ()));
          is_false ~msg:"key participates"
            (Workspace.Notice.equal (make ()) (make ~key:"other" ()));
          List.iter
            (fun (severity, text) ->
              equal string ~msg:"severity pp is its wire spelling" text
                (Format.asprintf "%a" Workspace.Notice.Severity.pp severity))
            [
              (Workspace.Notice.Severity.Info, "info");
              (Workspace.Notice.Severity.Warning, "warning");
              (Workspace.Notice.Severity.Error, "error");
            ];
          let printed =
            Format.asprintf "%a" Workspace.Notice.pp (make ~body:"b" ())
          in
          is_true ~msg:"pp names the producer"
            (String.includes ~affix:"dune" printed);
          is_true ~msg:"pp names the coalescing key"
            (String.includes ~affix:"k" printed));
      test "encodes the documented notice object" (fun () ->
          let full =
            Workspace.Notice.make ~source:"dune"
              ~severity:Workspace.Notice.Severity.Warning ~title:"build broken"
              ~body:"3 errors in lib/foo" ~key:"dune:health" ()
          in
          is_true ~msg:"wire shape carries the body when present"
            (Json.equal
               (notice_object ~body:"3 errors in lib/foo" ())
               (json_encode Workspace.Notice.jsont full));
          let bare =
            Workspace.Notice.make ~source:"dune"
              ~severity:Workspace.Notice.Severity.Warning ~title:"build broken"
              ~key:"dune:health" ()
          in
          is_true ~msg:"an absent body is omitted, never null"
            (Json.equal (notice_object ())
               (json_encode Workspace.Notice.jsont bare));
          equal (result notice_value pass) ~msg:"decode inverts encode"
            (Ok full)
            (Json.decode Workspace.Notice.jsont
               (notice_object ~body:"3 errors in lib/foo" ())));
      prop "round-trips through jsont" notice_case_gen (fun notice ->
          equal notice_value notice
            (json_decode Workspace.Notice.jsont
               (json_encode Workspace.Notice.jsont notice)));
      cases "notice decode fails closed" ~name:fst notice_rejections
        (fun (_, json) ->
          is_true (Result.is_error (Json.decode Workspace.Notice.jsont json)));
    ]

(* Protected metadata *)

let protected_metadata =
  group "protected metadata"
    [
      test "the guarded names are .git and the agent state dir" (fun () ->
          equal (list string) ~msg:"single-sourced constant"
            [ ".git"; ".mentat" ] Workspace.protected_meta_names);
      test "flags a first-component protected name, existing or not" (fun () ->
          let root = make_root "/workspace" in
          equal (option string) ~msg:".git directory" (Some ".git")
            (Workspace.protected_meta_component (make_path root ".git/config"));
          equal (option string) ~msg:".mentat directory" (Some ".mentat")
            (Workspace.protected_meta_component
               (make_path root ".mentat/agents.json"));
          equal (option string) ~msg:"the bare protected name" (Some ".git")
            (Workspace.protected_meta_component (make_path root ".git"));
          equal (option string)
            ~msg:"a not-yet-existing target under .git is still caught"
            (Some ".git")
            (Workspace.protected_meta_component
               (make_path root ".git/hooks/pre-commit")));
      test "does not flag non-first or non-matching components" (fun () ->
          let root = make_root "/workspace" in
          equal (option string) ~msg:"an ordinary file" None
            (Workspace.protected_meta_component (make_path root "src/a.ml"));
          equal (option string) ~msg:"the root path" None
            (Workspace.protected_meta_component (make_path root "."));
          equal (option string) ~msg:"a string-prefix name is not the name" None
            (Workspace.protected_meta_component (make_path root ".gitignore"));
          (* Nesting-correct: the address carries its own root, so a protected
             name below the first component is not flagged. *)
          equal (option string) ~msg:".git below the first component" None
            (Workspace.protected_meta_component (make_path root "src/.git/x")));
      test "nesting-correctness follows the path's own root" (fun () ->
          (* /ws/sub/.git addressed via the deep root has rel .git (flagged);
             addressed via the outer root has rel sub/.git (not flagged). *)
          let deep = make_root "/ws/sub" in
          let outer = make_root "/ws" in
          equal (option string) ~msg:"via the deep root" (Some ".git")
            (Workspace.protected_meta_component (make_path deep ".git"));
          equal (option string) ~msg:"via the outer root" None
            (Workspace.protected_meta_component (make_path outer "sub/.git")));
    ]

(* Error surfaces *)

let errors =
  group "errors"
    [
      test "workspace errors have informative, matching diagnostics" (fun () ->
          let a = make_root "/a" and b = make_root "/b" in
          let all =
            [
              Workspace.Error.Conflicting_root { existing = a; duplicate = b };
              Workspace.Error.Root_not_in_workspace (Workspace.Root.key a);
            ]
          in
          List.iter
            (fun e ->
              is_false ~msg:"non-empty message"
                (String.is_empty (Workspace.Error.message e));
              equal string ~msg:"pp renders message"
                (Workspace.Error.message e)
                (Format.asprintf "%a" Workspace.Error.pp e);
              is_true ~msg:"reflexive equality" (Workspace.Error.equal e e))
            all;
          is_false ~msg:"constructors are distinguished"
            (Workspace.Error.equal
               (Workspace.Error.Root_not_in_workspace (Workspace.Root.key a))
               (Workspace.Error.Root_not_in_workspace (Workspace.Root.key b))));
      test "resolve errors have informative, matching diagnostics" (fun () ->
          let all =
            [
              Workspace.Resolve_error.Outside_workspace (abs "/x");
              Workspace.Resolve_error.Invalid_input Syntax.Error.Empty;
              Workspace.Resolve_error.Unknown_root
                (Workspace.Root.Key.of_string_exn "unknown");
            ]
          in
          List.iter
            (fun e ->
              is_false ~msg:"non-empty message"
                (String.is_empty (Workspace.Resolve_error.message e));
              equal string ~msg:"pp renders message"
                (Workspace.Resolve_error.message e)
                (Format.asprintf "%a" Workspace.Resolve_error.pp e);
              is_true ~msg:"reflexive equality"
                (Workspace.Resolve_error.equal e e))
            all;
          is_false ~msg:"constructors are distinguished"
            (Workspace.Resolve_error.equal
               (Workspace.Resolve_error.Outside_workspace (abs "/x"))
               (Workspace.Resolve_error.Invalid_input Syntax.Error.Empty)));
    ]

let () =
  run "mentat.workspace"
    [
      root_keys;
      roots;
      addresses;
      workspace;
      resolution;
      bindings;
      path_wire;
      notices;
      protected_metadata;
      errors;
    ]
