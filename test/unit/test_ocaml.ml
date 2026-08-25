(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

open Windtrap
module Ocaml = Mentat_ocaml

let expect_invalid_arg msg f =
  match f () with
  | _ -> failf "%s: expected Invalid_argument" msg
  | exception Invalid_argument _ -> ()

let position_and_range () =
  let p1 = Ocaml.Position.make ~line:1 ~column:0 in
  let p2 = Ocaml.Position.make ~line:3 ~column:4 in
  let range = Ocaml.Range.make ~start:p1 ~end_:p2 in
  let same_start = Ocaml.Range.make ~start:p1 ~end_:p1 in
  let root =
    Mentat_workspace.Root.of_dir (Lpath.Abs.of_string_exn "/workspace")
  in
  let path =
    Mentat_workspace.Path.make
      ~root_key:(Mentat_workspace.Root.key root)
      (Lpath.Rel.of_string_exn "lib/example.ml")
  in
  let location = Ocaml.Location.make ~path ~range in
  equal int ~msg:"line" 1 (Ocaml.Position.line p1);
  equal int ~msg:"column" 4 (Ocaml.Position.column p2);
  is_true ~msg:"location start"
    (Ocaml.Position.equal p1 (Ocaml.Location.start location));
  is_true ~msg:"location end"
    (Ocaml.Position.equal p2 (Ocaml.Location.end_ location));
  is_true ~msg:"range order" (Ocaml.Range.compare same_start range < 0);
  is_true ~msg:"range contains child"
    (Ocaml.Range.contains ~outer:range same_start);
  expect_invalid_arg "line lower bound" (fun () ->
      Ocaml.Position.make ~line:0 ~column:0);
  expect_invalid_arg "column lower bound" (fun () ->
      Ocaml.Position.make ~line:1 ~column:(-1));
  expect_invalid_arg "range order" (fun () ->
      Ocaml.Range.make ~start:p2 ~end_:p1)

let diagnostic_invariants () =
  let source = Ocaml.Diagnostic.Source.other "ppx-driver" in
  let diagnostic =
    Ocaml.Diagnostic.make ~source ~severity:Ocaml.Diagnostic.Severity.Warning
      ~code:"32"
      ~tags:[ Ocaml.Diagnostic.Tag.Unnecessary ]
      "unused value"
  in
  equal string ~msg:"source string" "ppx-driver"
    (Ocaml.Diagnostic.Source.to_string (Ocaml.Diagnostic.source diagnostic));
  equal (option string) ~msg:"code" (Some "32")
    (Ocaml.Diagnostic.code diagnostic);
  expect_invalid_arg "empty diagnostic message" (fun () ->
      Ocaml.Diagnostic.make ~source:Ocaml.Diagnostic.Source.merlin
        ~severity:Ocaml.Diagnostic.Severity.Error "");
  expect_invalid_arg "duplicate tags" (fun () ->
      Ocaml.Diagnostic.make ~source:Ocaml.Diagnostic.Source.merlin
        ~severity:Ocaml.Diagnostic.Severity.Warning
        ~tags:
          [ Ocaml.Diagnostic.Tag.Deprecated; Ocaml.Diagnostic.Tag.Deprecated ]
        "deprecated value");
  expect_invalid_arg "bad source label" (fun () ->
      ignore (Ocaml.Diagnostic.Source.other "Bad_Source"));
  expect_invalid_arg "reserved source label" (fun () ->
      ignore (Ocaml.Diagnostic.Source.other "dune"));
  begin match Ocaml.Diagnostic.Source.other "ppx-driver" with
  | Ocaml.Diagnostic.Source.Other "ppx-driver" -> ()
  | source ->
      failf "unexpected other source %s"
        (Ocaml.Diagnostic.Source.to_string source)
  end;
  let related =
    Ocaml.Diagnostic.Related.make "in expansion of generated code"
  in
  let diagnostic_with_related =
    Ocaml.Diagnostic.make ~source ~severity:Ocaml.Diagnostic.Severity.Warning
      ~code:"32"
      ~tags:[ Ocaml.Diagnostic.Tag.Unnecessary ]
      ~related:[ related ] "unused value"
  in
  is_true ~msg:"diagnostic compare distinguishes related information"
    (Ocaml.Diagnostic.compare diagnostic diagnostic_with_related < 0);
  is_true ~msg:"diagnostic compare matches equality"
    (Ocaml.Diagnostic.compare diagnostic diagnostic = 0);
  is_true ~msg:"diagnostic severity order"
    (Ocaml.Diagnostic.Severity.compare Ocaml.Diagnostic.Severity.Error
       Ocaml.Diagnostic.Severity.Warning
    < 0);
  is_true ~msg:"diagnostic tag order"
    (Ocaml.Diagnostic.Tag.compare Ocaml.Diagnostic.Tag.Unnecessary
       Ocaml.Diagnostic.Tag.Deprecated
    < 0)

let project_description_invariants () =
  let root =
    Mentat_workspace.Root.of_dir (Lpath.Abs.of_string_exn "/workspace")
  in
  let path rel =
    Mentat_workspace.Path.make
      ~root_key:(Mentat_workspace.Root.key root)
      (Lpath.Rel.of_string_exn rel)
  in
  let foo = Ocaml.Module_name.make "Foo" in
  let bar = Ocaml.Module_name.make "Bar" in
  let baz = Ocaml.Module_name.make "Baz" in
  let unit_ =
    Ocaml.Project.Compilation_unit.make ~impl:(path "lib/foo.ml")
      ~intf:(path "lib/foo.mli")
      ~interface_deps:(Ocaml.Project.Deps.known [ bar ])
      ~implementation_deps:(Ocaml.Project.Deps.known [ baz ])
      foo
  in
  let lib_id = Ocaml.Project.Component.Id.library "foo" in
  let ext_id = Ocaml.Project.Component.Id.external_library "unix" in
  let exe_id =
    Ocaml.Project.Component.Id.executable ~dir:(path "bin") ~name:"main"
  in
  equal string ~msg:"executable id uses stable workspace path identity"
    {|executable:"/workspace":"bin":main|}
    (Ocaml.Project.Component.Id.to_string exe_id);
  let external_dep = Ocaml.Project.Component.external_library ~name:"unix" () in
  let library =
    Ocaml.Project.Component.local_library ~name:"foo" ~source_dir:(path "lib")
      ~units:[ unit_ ]
      ~requires:(Ocaml.Project.Deps.known [ ext_id ])
      ()
  in
  let executable =
    Ocaml.Project.Component.executable ~dir:(path "bin") ~name:"main"
      ~requires:Ocaml.Project.Deps.unknown ()
  in
  let resolved_executable =
    Ocaml.Project.Component.with_requires
      (Ocaml.Project.Deps.known [ lib_id ])
      executable
  in
  equal string ~msg:"library id"
    (Ocaml.Project.Component.Id.to_string lib_id)
    (Ocaml.Project.Component.id library |> Ocaml.Project.Component.Id.to_string);
  equal string ~msg:"external id"
    (Ocaml.Project.Component.Id.to_string ext_id)
    (Ocaml.Project.Component.id external_dep
    |> Ocaml.Project.Component.Id.to_string);
  equal string ~msg:"executable id"
    (Ocaml.Project.Component.Id.to_string exe_id)
    (Ocaml.Project.Component.id executable
    |> Ocaml.Project.Component.Id.to_string);
  begin match Ocaml.Project.Component.requires resolved_executable with
  | Ocaml.Project.Deps.Known [ id ] ->
      equal string ~msg:"with_requires"
        (Ocaml.Project.Component.Id.to_string lib_id)
        (Ocaml.Project.Component.Id.to_string id)
  | Ocaml.Project.Deps.Unknown | Ocaml.Project.Deps.Known _ ->
      failf "unexpected with_requires result"
  end;
  let test =
    Ocaml.Project.Test.make ~component:lib_id ~name:"foo_tests"
      ~source_dir:(path "test") ~target:"@test/runtest" ~enabled:true ()
  in
  let project =
    Ocaml.Project.make ~root:(path ".") ~build_context:"default" ~tests:[ test ]
      [ library; external_dep; executable ]
  in
  equal int ~msg:"components" 3 (List.length (Ocaml.Project.components project));
  equal int ~msg:"tests" 1 (List.length (Ocaml.Project.tests project));
  begin match Ocaml.Project.dependencies project lib_id with
  | Some (Ocaml.Project.Deps.Known [ dep ]) ->
      equal string ~msg:"library dependency" "unix"
        (Ocaml.Project.Component.name dep)
  | None | Some (Ocaml.Project.Deps.Unknown | Ocaml.Project.Deps.Known _) ->
      failf "unexpected known dependency result"
  end;
  begin match Ocaml.Project.dependencies project exe_id with
  | Some Ocaml.Project.Deps.Unknown -> ()
  | None | Some (Ocaml.Project.Deps.Known _) ->
      failf "executable deps should be unknown"
  end;
  begin match
    Ocaml.Project.dependencies project
      (Ocaml.Project.Component.Id.library "missing")
  with
  | None -> ()
  | Some _ -> failf "missing component dependencies should be None"
  end;
  equal int ~msg:"local components" 2
    (List.length (Ocaml.Project.local_components project));
  equal int ~msg:"external components" 1
    (List.length (Ocaml.Project.external_components project));
  expect_invalid_arg "duplicate component ids" (fun () ->
      Ocaml.Project.make [ library; library ]);
  expect_invalid_arg "duplicate dependency ids" (fun () ->
      Ocaml.Project.Component.executable ~dir:(path "bad") ~name:"bad"
        ~requires:(Ocaml.Project.Deps.known [ ext_id; ext_id ])
        ());
  expect_invalid_arg "empty module dependency" (fun () ->
      ignore (Ocaml.Module_name.make ""));
  List.iter
    (fun name ->
      expect_invalid_arg ("invalid module name " ^ name) (fun () ->
          ignore (Ocaml.Module_name.make name)))
    [ "foo"; "Foo.Bar"; "Foo-bar"; " Foo"; "Foo\000Bar" ];
  expect_invalid_arg "empty test target" (fun () ->
      Ocaml.Project.Test.make ~name:"bad" ~source_dir:(path "test") ~target:""
        ~enabled:true ());
  expect_invalid_arg "unknown required component" (fun () ->
      let bad =
        Ocaml.Project.Component.executable ~dir:(path "bad") ~name:"bad"
          ~requires:
            (Ocaml.Project.Deps.known
               [ Ocaml.Project.Component.Id.external_library "missing" ])
          ()
      in
      Ocaml.Project.make [ bad ]);
  expect_invalid_arg "test references unknown component" (fun () ->
      let bad_test =
        Ocaml.Project.Test.make
          ~component:(Ocaml.Project.Component.Id.library "missing")
          ~name:"bad" ~source_dir:(path "test") ~target:"@bad" ~enabled:true ()
      in
      Ocaml.Project.make ~tests:[ bad_test ] [ library; external_dep ])

(* Build-change law helpers. *)

let component_gen =
  Gen.string_of ~size:(Gen.int_range 1 5) (Gen.char_range 'a' 'z')

let finding ?(lane = Mentat_ocaml.Finding.Lane.Build)
    ?(severity = Mentat_ocaml.Finding.Severity.Error) ?path ?location head =
  Mentat_ocaml.Finding.v ~lane ~severity ?path ?location ~head ()

let lint_finding ?(severity = Mentat_ocaml.Finding.Severity.Warning) head =
  Mentat_ocaml.Finding.v ~lane:Mentat_ocaml.Finding.Lane.Lint ~severity ~head
    ()

let reading ?lint_live ?(empty_confirmed = true) findings =
  Mentat_ocaml.Build_change.Reading.make ?lint_live ~empty_confirmed findings

let step state reading = Mentat_ocaml.Build_change.step state reading

let titles changes =
  List.map
    (fun change -> Mentat_workspace.Notice.title (Mentat_ocaml.Build_change.notice change))
    changes

let build_change =
  group "build change law"
    [
      test "identity is content: positions move silently, duplicates collapse"
        (fun () ->
          let e ?location () =
            finding ~path:"lib/a.ml" ?location "Unbound value restock"
          in
          let state = Mentat_ocaml.Build_change.State.initial in
          let changes, state =
            step state (Some (reading [ e ~location:"lib/a.ml:5:0-5:7" () ]))
          in
          equal (list string) ~msg:"first failing states the finding"
            [ "Build failing (1 error: 1 new)" ]
            (titles changes);
          let changes, state =
            step state
              (Some
                 (reading
                    [
                      e ~location:"lib/a.ml:9:0-9:7" ();
                      e ~location:"lib/a.ml:9:0-9:7" ();
                    ]))
          in
          equal int ~msg:"moved and duplicated is silent" 0
            (List.length changes);
          let changes, _ =
            step state
              (Some (reading [ finding ~path:"lib/a.ml" "A different error" ]))
          in
          equal (list string) ~msg:"a different head at the same path notices"
            [ "Build failing (1 error: 1 new, 1 resolved)" ]
            (titles changes));
      test "step is idempotent and no-reading is identity" (fun () ->
          let state = Mentat_ocaml.Build_change.State.initial in
          let r = reading [ finding "boom" ] in
          let changes, state = step state (Some r) in
          equal int ~msg:"first states" 1 (List.length changes);
          let changes, state = step state (Some r) in
          equal int ~msg:"same reading again is silent" 0 (List.length changes);
          let changes, state = step state None in
          equal int ~msg:"no reading is silent" 0 (List.length changes);
          let changes, _ = step state (Some (reading [])) in
          equal (list string) ~msg:"then a clean reading recovers"
            [ "Build recovered" ] (titles changes));
      test "recovery needs confirmation and a non-empty baseline" (fun () ->
          let state = Mentat_ocaml.Build_change.State.initial in
          let changes, state = step state (Some (reading [])) in
          equal int ~msg:"clean over a clean baseline is silent" 0
            (List.length changes);
          let _, state = step state (Some (reading [ finding "boom" ])) in
          let changes, state =
            step state (Some (reading ~empty_confirmed:false []))
          in
          equal int ~msg:"an unconfirmed empty reading is withheld" 0
            (List.length changes);
          let changes, _ = step state (Some (reading [ finding "boom" ])) in
          equal int
            ~msg:"the withheld reading moved no baseline: same set is silent" 0
            (List.length changes));
      test "lanes are independent and an absent lint lane is frozen" (fun () ->
          let lint_finding =
            lint_finding
              "physical comparison has a non-immediate operand \
               [suspicious-physical-equality]"
          in
          let state = Mentat_ocaml.Build_change.State.initial in
          let changes, state =
            step state (Some (reading [ finding "boom"; lint_finding ]))
          in
          equal (list string) ~msg:"both lanes state, build first"
            [ "Build failing (1 error: 1 new)"; "1 finding (1 new)" ]
            (titles changes);
          let changes, state = step state (Some (reading [])) in
          equal (list string)
            ~msg:"build recovers; the absent lint lane says nothing"
            [ "Build recovered" ] (titles changes);
          let changes, _ = step state (Some (reading [ lint_finding ])) in
          equal int ~msg:"identical lint findings returning are not re-stated"
            0 (List.length changes));
      test "a lint lane reading empty and confirmed is lint clean" (fun () ->
          let lint_finding =
            lint_finding "needless emptiness test [needless-list-length]"
          in
          let state = Mentat_ocaml.Build_change.State.initial in
          let _, state = step state (Some (reading [ lint_finding ])) in
          let changes, _ = step state (Some (reading ~lint_live:true [])) in
          equal (list string) ~msg:"lint clean" [ "Lint clean" ]
            (titles changes));
      test "notice bytes: severity, title grammar, body, coalescing keys"
        (fun () ->
          let e1 =
            finding ~path:"lib/inventory.ml"
              ~location:"lib/inventory.ml:5:17-5:40"
              "This expression has type string but an expression was expected \
               of type int"
          in
          let e2 =
            finding ~path:"lib/store.ml" ~location:"lib/store.ml:12:3-12:9"
              "Unbound value restock"
          in
          let state = Mentat_ocaml.Build_change.State.initial in
          let changes, state = step state (Some (reading [ e1; e2 ])) in
          let notice =
            Mentat_ocaml.Build_change.notice (List.nth changes 0)
          in
          equal string ~msg:"source" "dune" (Mentat_workspace.Notice.source notice);
          is_true ~msg:"severity error"
            (Mentat_workspace.Notice.Severity.equal
               (Mentat_workspace.Notice.severity notice)
               Mentat_workspace.Notice.Severity.Error);
          equal string ~msg:"title" "Build failing (2 errors: 2 new)"
            (Mentat_workspace.Notice.title notice);
          equal (option string) ~msg:"body lists fresh findings"
            (Some
               "lib/inventory.ml:5:17-5:40: This expression has type string \
                but an expression was expected of type int\n\
                lib/store.ml:12:3-12:9: Unbound value restock")
            (Mentat_workspace.Notice.body notice);
          equal string ~msg:"key" "dune.build" (Mentat_workspace.Notice.key notice);
          let changes, _ = step state (Some (reading [ e1 ])) in
          let notice =
            Mentat_ocaml.Build_change.notice (List.nth changes 0)
          in
          equal string ~msg:"resolved title"
            "Build failing (1 error: 0 new, 1 resolved)"
            (Mentat_workspace.Notice.title notice);
          equal (option string) ~msg:"unchanged trailer"
            (Some "1 unchanged since the last notice")
            (Mentat_workspace.Notice.body notice));
      test "a warnings-only build lane is failing at warning severity"
        (fun () ->
          let w =
            finding ~severity:Mentat_ocaml.Finding.Severity.Warning
              ~path:"lib/a.ml" "unused open"
          in
          let changes, _ =
            step Mentat_ocaml.Build_change.State.initial (Some (reading [ w ]))
          in
          let notice =
            Mentat_ocaml.Build_change.notice (List.nth changes 0)
          in
          equal string ~msg:"title counts warnings"
            "Build failing (1 warning: 1 new)"
            (Mentat_workspace.Notice.title notice);
          is_true ~msg:"severity warning"
            (Mentat_workspace.Notice.Severity.equal
               (Mentat_workspace.Notice.severity notice)
               Mentat_workspace.Notice.Severity.Warning));
      prop
        "property: permutation, duplication, and moved positions never \
         re-notice"
        (Gen.list ~size:(Gen.int_range 1 6)
           (Gen.pair component_gen (Gen.int_range 0 99)))
        (fun heads ->
          let findings location =
            List.map
              (fun (head, line) ->
                finding ~path:"lib/a.ml"
                  ~location:
                    (Printf.sprintf "lib/a.ml:%d:0-%d:%d" (location + line)
                       (location + line) (String.length head))
                  ("error " ^ head))
              heads
          in
          let _, state =
            step Mentat_ocaml.Build_change.State.initial
              (Some (reading (findings 0)))
          in
          let moved_and_shuffled =
            List.rev (findings 7) @ findings 7
          in
          let changes, _ = step state (Some (reading moved_and_shuffled)) in
          equal int
            ~msg:"same heads at new positions, reversed and duplicated, are \
                  silent"
            0 (List.length changes));
      test "the body elides past twenty fresh findings" (fun () ->
          let findings =
            List.init 23 (fun i ->
                finding ~path:"lib/a.ml" ("error " ^ string_of_int i))
          in
          let changes, _ =
            step Mentat_ocaml.Build_change.State.initial
              (Some (reading findings))
          in
          let body =
            Option.value ~default:""
              (Mentat_workspace.Notice.body
                 (Mentat_ocaml.Build_change.notice (List.nth changes 0)))
          in
          let lines = String.split_on_char '\n' body in
          equal int ~msg:"20 lines then the elision line" 21
            (List.length lines);
          equal (option string) ~msg:"elision counts the rest"
            (Some "… and 3 more")
            (List.nth_opt lines 20));
    ]


let () =
  run "mentat.ocaml"
    [
      test "position and range" position_and_range;
      test "diagnostic invariants" diagnostic_invariants;
      test "project description invariants" project_description_invariants;
      build_change;
    ]
