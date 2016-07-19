open! Core_kernel.Std
open! Import

module Model = struct
  type t = { entries : Entry.Model.t Entry_id.Map.t
           ; focus : (Entry_id.t * Focus_point.t option) option
           ; search_string : string
           }
  [@@deriving fields, sexp]

  let name_found_by_search ~search_string name =
    String.(=) search_string ""
    || String.is_prefix (String.lowercase name)
         ~prefix:(String.lowercase search_string)

  let filtered_entries t =
    Map.filteri t.entries ~f:(fun ~key:_ ~data:e ->
      name_found_by_search ~search_string:t.search_string (Entry.Model.name e))

end

module Action = struct
  type t = | Entry of (Entry_id.t * Focus_point.t option) option * Entry.Action.t
           | Set_outer_focus of Entry_id.t
           | Set_inner_focus of Focus_point.t
           | Move_outer_focus of focus_dir
           | Move_inner_focus of focus_dir
           | Set_search_string of string
           | Raise of Error.t
           | Raise_js
           | Nop
           | Dump_state
           | Kick_all
           | Kick_n of int
  [@@deriving sexp]

  let should_log _ = true

  let kick_n n = Kick_n n
  let kick_all = Kick_all

  let nop = Nop

  let do_kick_all (model:Model.t) =
    if Random.float 1. < 0.6 then model
    else
      let entries = Map.map model.entries ~f:Entry.Model.kick in
      { model with entries }

  let do_kick_one (model:Model.t) =
    let pos = Random.int (Map.length model.entries) in
    match Map.nth model.entries pos with
    | None -> model
    | Some (key,_) ->
      let entries =
        Map.change model.entries key ~f:(function
          | None -> None
          | Some x -> Some (Entry.Model.kick x))
      in
      { model with entries }

  let do_kick_n model n =
    Sequence.fold ~init:model (Sequence.range 0 n)
      ~f:(fun old (_:int) -> do_kick_one old)

  let entry_apply (m:Model.t) entry_id focus_point action =
    let entries =
      Map.change m.entries entry_id ~f:(function
        | None -> None
        | Some m -> Some (Entry.Action.apply action focus_point m))
    in
    { m with entries }

  let move_inner_focus (dir:focus_dir) (m:Model.t) =
    let focus =
      match m.focus with
      | None -> None
      | Some (entry_id,fp) ->
        match Map.find m.entries entry_id with
        | None -> None
        | Some entry ->
          let fp = Entry.Model.move_focus entry fp dir in
          Some (entry_id,fp)
    in
    { m with focus }

  let move_outer_focus dir (m:Model.t) =
    let (outer,inner) =
      match m.focus with
      | None -> (None,None)
      | Some (outer, inner) -> (Some outer, inner)
    in
    match move_map_focus (Model.filtered_entries m) outer dir with
    | None -> {m with focus = None }
    | Some new_outer -> { m with focus = Some (new_outer,inner) }
  ;;

  let set_outer_focus entry_id (m:Model.t) =
    let focus =
      match m.focus with
      | None -> Some (entry_id,None)
      | Some (_,focus_point) -> Some (entry_id,focus_point)
    in
    { m with focus }

  let set_inner_focus fp (m:Model.t) =
    let focus =
      match m.focus with
      | None -> None
      | Some (entry_id,_) -> Some (entry_id,Some fp)
    in
    { m with focus }

  let apply t ~schedule:_ (m:Model.t) =
    match t with
    | Move_outer_focus dir ->
      move_outer_focus dir m
    | Move_inner_focus dir ->
      move_inner_focus dir m
    | Set_outer_focus entry_id ->
      set_outer_focus entry_id m
    | Set_inner_focus fp ->
      set_inner_focus fp m
    | Kick_all ->
      do_kick_all m
    | Kick_n n ->
      do_kick_n m n
    | Entry (focus,action) ->
      begin match focus with
      | None -> m
      | Some (entry_id,focus_point) ->
        entry_apply m entry_id focus_point action
      end
    | Raise err ->
      Error.raise err
    | Raise_js ->
      Js_of_ocaml.Js.Unsafe.js_expr "xxxxxxxxxxxxx.yy()"
    | Dump_state ->
      logf !"%{sexp:Model.t}" m; m
    | Nop -> m
    | Set_search_string search_string -> { m with search_string }
  ;;

end

let view (m:Model.t Incr.t) ~schedule =
  let open Vdom in
  let open Incr.Let_syntax in
  let set_inner_focus fp = schedule (Action.Set_inner_focus fp) in
  let focus = m >>| Model.focus in
  let on_keypress =
    let%map focus = focus in
    Attr.on_keypress (fun ev ->
      let kp = Keypress.of_event ev in
      match kp.key with
      | Char 'k' -> schedule (Move_outer_focus Prev)
      | Char 'j' -> schedule (Move_outer_focus Next)
      | Char 'u' -> schedule (Move_inner_focus Prev)
      | Char 'i' -> schedule (Move_inner_focus Next)
      | Char 'x' -> if kp.ctrl then schedule (Raise (Error.of_string "got X"))
      | Char 'y' -> if kp.ctrl then schedule Raise_js
      | Char 'd' -> schedule Nop
      | Char 's' -> schedule Dump_state
      | Char 'e' -> schedule (Entry (focus, Toggle_collapse))
      | Char ('+' | '=') -> schedule (Entry (focus, Bump Incr))
      | Char ('-' | '_') -> schedule (Entry (focus, Bump Decr))
      | _ -> ()
    )
  in
  (* Right now, the incrementality of this is terrible.  Waiting on better support from
     Incremental. *)
  let input =
    Node.input [ Attr.create "type" "text"
               ; Attr.on_input (fun _ev text -> schedule (Set_search_string text))
               ] []
  in
  let entries       = m >>| Model.entries       in
  let search_string = m >>| Model.search_string in
  let%map entries =
    Incr.Map.filter_mapi' entries ~f:(fun ~key:entry_id ~data:entry ->
      logf !"creating %{Entry_id}" entry_id;
      let name = entry >>| Entry.Model.name in
      let%bind name = name and search_string = search_string in
      if not (Model.name_found_by_search ~search_string name) then Incr.const None
      else
        let focus_me () = schedule (Action.Set_outer_focus entry_id) in
        let focus =
          match%map focus with
          | None -> Entry.Unfocused
          | Some (entry_id', fp) ->
            if Entry_id.(=) entry_id entry_id' then Entry.Focused fp
            else Entry.Unfocused
        in
        let%map view =
          Entry.view entry entry_id ~focus ~focus_me ~set_inner_focus
        in
        Some view
    )
  and on_keypress = on_keypress
  in
  Node.body [on_keypress] (input :: Map.data entries)


let example ~entries : Model.t =
  let entries =
    List.init entries ~f:(fun _ -> Entry.Model.example ())
    |> List.mapi ~f:(fun i x -> (Entry_id.create i,x))
    |> Entry_id.Map.of_alist_exn
  in
  let focus =
    match Map.min_elt entries with
    | Some (k,_) -> Some (k,None)
    | None -> None
  in
  { focus; entries; search_string = "" }