(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core
open OUnit2
open Analysis
open Ast
open Test

let assert_liveness_errors ~context =
  let check ~configuration ~global_resolution ~source =
    TypeCheck.run ~configuration ~global_resolution ~source |> ignore;
    LivenessCheck.run ~configuration ~global_resolution ~source
  in
  assert_errors ~context ~check


let test_forward context =
  let assert_liveness_errors = assert_liveness_errors ~context in
  (* Assignments *)
  assert_liveness_errors
    {|
      x = 1
    |}
    ["Dead store [1003]: Value assigned to `x` is never used."];
  assert_liveness_errors
    {|
      x = 1
      y = x
    |}
    ["Dead store [1003]: Value assigned to `y` is never used."];
  assert_liveness_errors
    {|
      def foo(t: typing.Tuple[int, int]) -> None:
        x, y = t
    |}
    ["Dead store [1003]: Value assigned to `y` is never used."];
  assert_liveness_errors
    {|
      def foo() -> None:
        x, (y, z) = 1, (2, 3)
    |}
    ["Dead store [1003]: Value assigned to `z` is never used."];
  assert_liveness_errors
    {|
      def foo() -> None:
        [x, *y, z] = [1, 2, 3, 4, 5]
    |}
    ["Dead store [1003]: Value assigned to `z` is never used."];

  (* Parameters *)
  assert_liveness_errors
    {|
      def foo(x: int) -> None:
        y = 1
    |}
    [ "Dead store [1003]: Value assigned to `x` is never used.";
      "Dead store [1003]: Value assigned to `y` is never used." ];
  assert_liveness_errors
    {|
      def foo(x: int, y: int, z: int) -> None:
        a = z
    |}
    [ "Dead store [1003]: Value assigned to `x` is never used.";
      "Dead store [1003]: Value assigned to `y` is never used.";
      "Dead store [1003]: Value assigned to `a` is never used." ];

  (* Reassignment *)
  assert_liveness_errors
    {|
      x = 1
      x = 2
    |}
    [ "Dead store [1003]: Value assigned to `x` is never used.";
      "Dead store [1003]: Value assigned to `x` is never used." ];
  assert_liveness_errors
    {|
      x = 1
      x = 2
      x
    |}
    ["Dead store [1003]: Value assigned to `x` is never used."];

  (* Dead Code *)
  assert_liveness_errors
    {|
      def foo() -> None:
        x = 1
        return
        x
    |}
    ["Dead store [1003]: Value assigned to `x` is never used."];
  assert_liveness_errors
    {|
      def foo() -> None:
        x = 1
        if False:
          x
    |}
    ["Dead store [1003]: Value assigned to `x` is never used."];
  assert_liveness_errors
    {|
      def use(x: int) -> None:
        x

      def foo(test: bool) -> None:
        x = 1
        if test:
          sys.exit(0)
          use(x)
    |}
    ["Dead store [1003]: Value assigned to `x` is never used."]


let test_bottom context =
  let assert_bottom source bottom =
    let module Context = struct
      let global_resolution =
        ScratchProject.setup ~context [] |> ScratchProject.build_global_resolution


      let errors = Location.Reference.Table.create ()
    end
    in
    let module State = LivenessCheck.State (Context) in
    let state =
      let parsed =
        parse source
        |> function
        | { Source.statements = statement :: rest; _ } -> statement :: rest
        | _ -> failwith "unable to parse test"
      in
      List.fold
        ~f:(fun state statement -> State.forward ~key:0 state ~statement)
        ~init:(State.initial ~state:None ~define:(Node.create_with_default_location mock_define))
        parsed
    in
    let { State.bottom = actual_bottom; _ } = state in
    assert_equal bottom actual_bottom
  in
  assert_bottom {|
      x = 1
    |} false;
  assert_bottom {|
      assert True
    |} false;
  assert_bottom {|
      assert False
    |} true;
  assert_bottom {|
      x = 1
      sys.exit(0)
    |} true


let test_nested_defines context =
  let assert_liveness_errors = assert_liveness_errors ~context in
  assert_liveness_errors
    {|
      x = 1
      def foo() -> None:
        y = 1
    |}
    [ "Dead store [1003]: Value assigned to `x` is never used.";
      "Dead store [1003]: Value assigned to `y` is never used." ];
  assert_liveness_errors
    {|
      x = 1
      def foo() -> None:
        y = 1
        def bar() -> None:
          z = 1
    |}
    [ "Dead store [1003]: Value assigned to `x` is never used.";
      "Dead store [1003]: Value assigned to `y` is never used.";
      "Dead store [1003]: Value assigned to `z` is never used." ];
  assert_liveness_errors
    {|
      x = 1
      def foo() -> None:
        y = 1
        def bar() -> None:
          z = y
    |}
    [ "Dead store [1003]: Value assigned to `x` is never used.";
      "Dead store [1003]: Value assigned to `z` is never used." ]


let () =
  "livenessCheck"
  >::: [ "forward" >:: test_forward;
         "bottom" >:: test_bottom;
         "nested_defines" >:: test_nested_defines ]
  |> Test.run
