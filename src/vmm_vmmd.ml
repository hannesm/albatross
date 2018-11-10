(* (c) 2017, 2018 Hannes Mehnert, all rights reserved *)

open Astring

open Vmm_core

open Rresult
open R.Infix

type 'a t = {
  wire_version : Vmm_commands.version ;
  console_counter : int64 ;
  stats_counter : int64 ;
  log_counter : int64 ;
  resources : Vmm_resources.t ;
  tasks : 'a String.Map.t ;
}

let init wire_version =
  let t = {
    wire_version ;
    console_counter = 1L ;
    stats_counter = 1L ;
    log_counter = 1L ;
    resources = Vmm_resources.empty ;
    tasks = String.Map.empty ;
  } in
  match Vmm_unix.find_block_devices () with
  | Error (`Msg msg) ->
    Logs.warn (fun m -> m "couldn't find block devices %s" msg) ;
    t
  | Ok devs ->
    let resources =
      List.fold_left (fun r (id, size) ->
          match Vmm_resources.insert_block r id size with
          | Error (`Msg msg) ->
            Logs.err (fun m -> m "couldn't insert block device %a (%dM): %s" pp_id id size msg) ;
            r
          | Ok r -> r)
        t.resources devs
    in
    { t with resources }

type service_out = [
  | `Stat of Vmm_commands.wire
  | `Log of Vmm_commands.wire
  | `Cons of Vmm_commands.wire
]

type out = [ service_out | `Data of Vmm_commands.wire ]

let log t id event =
  let data = (Ptime_clock.now (), event) in
  let header = Vmm_commands.{ version = t.wire_version ; sequence = t.log_counter ; id } in
  let log_counter = Int64.succ t.log_counter in
  Logs.debug (fun m -> m "log %a" Log.pp data) ;
  ({ t with log_counter }, `Log (header, `Data (`Log_data data)))

let handle_create t reply name vm_config =
  (match Vmm_resources.find_vm t.resources name with
   | Some _ -> Error (`Msg "VM with same name is already running")
   | None -> Ok ()) >>= fun () ->
  Logs.debug (fun m -> m "now checking resource policies") ;
  (Vmm_resources.check_vm_policy t.resources name vm_config >>= function
    | false -> Error (`Msg "resource policies don't allow creation of this VM")
    | true -> Ok ()) >>= fun () ->
  (match vm_config.block_device with
   | None -> Ok None
   | Some dev ->
     let block_device_name = block_name name dev in
     Logs.debug (fun m -> m "looking for block device %a" pp_id block_device_name) ;
     match Vmm_resources.find_block t.resources block_device_name with
     | Some (_, false) -> Ok (Some block_device_name)
     | Some (_, true) -> Error (`Msg "block device is busy")
     | None -> Error (`Msg "cannot find block device") ) >>= fun block_device ->
  (* prepare VM: save VM image to disk, create fifo, ... *)
  Vmm_unix.prepare name vm_config >>= fun taps ->
  Logs.debug (fun m -> m "prepared vm with taps %a" Fmt.(list ~sep:(unit ",@ ") string) taps) ;
  let cons_out =
    let header = Vmm_commands.{ version = t.wire_version ; sequence = t.console_counter ; id = name } in
    (header, `Command (`Console_cmd `Console_add))
  in
  Ok ({ t with console_counter = Int64.succ t.console_counter },
      [ `Cons cons_out ],
      `Create (fun t task ->
          (* actually execute the vm *)
          Vmm_unix.exec name vm_config taps block_device >>= fun vm ->
          Logs.debug (fun m -> m "exec()ed vm") ;
          Vmm_resources.insert_vm t.resources name vm >>= fun resources ->
          let tasks = String.Map.add (string_of_id name) task t.tasks in
          let t = { t with resources ; tasks } in
          let t, out = log t name (`Vm_start (name, vm.pid, vm.taps, None)) in
          Ok (t, [ reply (`String "created VM") ; out ], name, vm)))

let setup_stats t name vm =
  let stat_out = `Stats_add (vm.pid, vm.taps) in
  let header = Vmm_commands.{ version = t.wire_version ; sequence = t.stats_counter ; id = name } in
  let t = { t with stats_counter = Int64.succ t.stats_counter } in
  t, `Stat (header, `Command (`Stats_cmd stat_out))

let handle_shutdown t name vm r =
  (match Vmm_unix.shutdown name vm with
   | Ok () -> ()
   | Error (`Msg e) -> Logs.warn (fun m -> m "%s while shutdown vm %a" e pp_vm vm)) ;
  let resources = match Vmm_resources.remove_vm t.resources name with
    | Error (`Msg e) ->
      Logs.warn (fun m -> m "%s while removing vm %a from resources" e pp_vm vm) ;
      t.resources
    | Ok resources -> resources
  in
  let header = Vmm_commands.{ version = t.wire_version ; sequence = t.stats_counter ; id = name } in
  let tasks = String.Map.remove (string_of_id name) t.tasks in
  let t = { t with stats_counter = Int64.succ t.stats_counter ; resources ; tasks } in
  let t, logout = log t name (`Vm_stop (name, vm.pid, r))
  in
  (t, [ `Stat (header, `Command (`Stats_cmd `Stats_remove)) ; logout ])

let handle_policy_cmd t reply id = function
  | `Policy_remove ->
    Logs.debug (fun m -> m "remove policy %a" pp_id id) ;
    Vmm_resources.remove_policy t.resources id >>= fun resources ->
    Ok ({ t with resources }, [ reply (`String "removed policy") ], `End)
  | `Policy_add policy ->
    Logs.debug (fun m -> m "insert policy %a" pp_id id) ;
    let same_policy = match Vmm_resources.find_policy t.resources id with
      | None -> false
      | Some p' -> eq_policy policy p'
    in
    if same_policy then
      Ok (t, [ reply (`String "no modification of policy") ], `Loop)
    else
      Vmm_resources.insert_policy t.resources id policy >>= fun resources ->
      Ok ({ t with resources }, [ reply (`String "added policy") ], `Loop)
  | `Policy_info ->
    Logs.debug (fun m -> m "policy %a" pp_id id) ;
    let policies =
      Vmm_resources.fold t.resources id
        (fun _ _ policies -> policies)
        (fun prefix policy policies-> (prefix, policy) :: policies)
        (fun _ _ _ policies -> policies)
        []
    in
    match policies with
    | [] ->
      Logs.debug (fun m -> m "policies: couldn't find %a" pp_id id) ;
      Error (`Msg "policy: not found")
    | _ ->
      Ok (t, [ reply (`Policies policies) ], `End)

let handle_vm_cmd t reply id msg_to_err = function
  | `Vm_info ->
    Logs.debug (fun m -> m "info %a" pp_id id) ;
    let vms =
      Vmm_resources.fold t.resources id
        (fun id vm vms -> (id, vm.config) :: vms)
        (fun _ _ vms-> vms)
        (fun _ _ _ vms -> vms)
        []
    in
    begin match vms with
      | [] ->
        Logs.debug (fun m -> m "info: couldn't find %a" pp_id id) ;
        Error (`Msg "info: not found")
      | _ ->
        Ok (t, [ reply (`Vms vms) ], `End)
    end
  | `Vm_create vm_config -> handle_create t reply id vm_config
  | `Vm_force_create vm_config ->
    begin
      let resources =
        match Vmm_resources.remove_vm t.resources id with
        | Error _ -> t.resources
        | Ok r -> r
      in
      Vmm_resources.check_vm_policy resources id vm_config >>= function
      | false -> Error (`Msg "wouldn't match policy")
      | true -> match Vmm_resources.find_vm t.resources id with
        | None -> handle_create t reply id vm_config
        | Some vm ->
          Vmm_unix.destroy vm ;
          let id_str = string_of_id id in
          match String.Map.find_opt id_str t.tasks with
          | None -> handle_create t reply id vm_config
          | Some task ->
            let tasks = String.Map.remove id_str t.tasks in
            let t = { t with tasks } in
            Ok (t, [], `Wait_and_create
                  (task, fun t -> msg_to_err @@ handle_create t reply id vm_config))
    end
  | `Vm_destroy ->
    match Vmm_resources.find_vm t.resources id with
    | Some vm ->
      Vmm_unix.destroy vm ;
      let id_str = string_of_id id in
      let out, next =
        let s = reply (`String "destroyed vm") in
        match String.Map.find_opt id_str t.tasks with
        | None -> [ s ], `End
        | Some t -> [], `Wait (t, s)
      in
      let tasks = String.Map.remove id_str t.tasks in
      Ok ({ t with tasks }, out, next)
    | None -> Error (`Msg "destroy: not found")

let handle_block_cmd t reply id = function
  | `Block_remove ->
    Logs.debug (fun m -> m "removing block %a" pp_id id) ;
    begin match Vmm_resources.find_block t.resources id with
      | None -> Error (`Msg "remove block: not found")
      | Some (_, true) -> Error (`Msg "remove block: is in use")
      | Some (_, false) ->
        Vmm_unix.destroy_block id >>= fun () ->
        Vmm_resources.remove_block t.resources id >>= fun resources ->
        Ok ({ t with resources }, [ reply (`String "removed block") ], `End)
    end
  | `Block_add size ->
    begin
      Logs.debug (fun m -> m "insert block %a: %dMB" pp_id id size) ;
      match Vmm_resources.find_block t.resources id with
      | Some _ -> Error (`Msg "block device with same name already exists")
      | None ->
        Vmm_resources.check_block_policy t.resources id size >>= function
        | false -> Error (`Msg "adding block device would violate policy")
        | true ->
          Vmm_unix.create_block id size >>= fun () ->
          Vmm_resources.insert_block t.resources id size >>= fun resources ->
          Ok ({ t with resources }, [ reply (`String "added block device") ], `Loop)
    end
  | `Block_info ->
    Logs.debug (fun m -> m "block %a" pp_id id) ;
    let blocks =
      Vmm_resources.fold t.resources id
        (fun _ _ blocks -> blocks)
        (fun _ _ blocks-> blocks)
        (fun prefix size active blocks -> (prefix, size, active) :: blocks)
        []
    in
    match blocks with
    | [] ->
      Logs.debug (fun m -> m "block: couldn't find %a" pp_id id) ;
      Error (`Msg "block: not found")
    | _ ->
      Ok (t, [ reply (`Blocks blocks) ], `End)

let handle_command t (header, payload) =
  let msg_to_err = function
    | Ok x -> x
    | Error (`Msg msg) ->
      Logs.err (fun m -> m "error while processing command: %s" msg) ;
      (t, [ `Data (header, `Failure msg) ], `End)
  and reply x = `Data (header, `Success x)
  and id = header.Vmm_commands.id
  in
  msg_to_err (
    match payload with
    | `Command (`Policy_cmd pc) -> handle_policy_cmd t reply id pc
    | `Command (`Vm_cmd vc) -> handle_vm_cmd t reply id msg_to_err vc
    | `Command (`Block_cmd bc) -> handle_block_cmd t reply id bc
    | _ ->
      Logs.err (fun m -> m "ignoring %a" Vmm_commands.pp_wire (header, payload)) ;
      Error (`Msg "unknown command"))