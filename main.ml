let verbose = ref false

type status = Success | Error | Progress
let string_of_status = function
	| Success -> "success"
	| Error -> "error"
	| Progress -> "progress"

let status_types = [ Success; Error; Progress]

let compare_time a b =
	match a, b with
		| Some a, Some b -> compare a b
		| Some a, None -> -1
		| None, Some a -> 1
		| None, None -> 0

let string_of_time_diff ?suffix diff =
	let (units, amount) =
		let seconds = int_of_float diff in
		let minutes = seconds / 60 in
		if minutes < 2 then
			("second", seconds)
		else
			let hours = minutes / 60 in
			if hours < 2 then
				("minute", minutes)
			else
				let days = hours / 24 in
				if days < 2 then
					("hour", hours)
				else
					("day", days)
	in
	let units = if amount = 1 then units else units ^ "s" in
	let suffix = match suffix with None -> "" | Some s -> " " ^ s in
	Printf.sprintf "%d %s%s" amount units suffix

let string_ago_of_time_diff = string_of_time_diff ~suffix:"ago"

let progress_desc = function
	| None -> ""
	| Some diff -> Printf.sprintf " (but was in progress %s)" (string_ago_of_time_diff diff)

let process ~desc ~max_age =
	let rec loop ~progress = function
		| [] -> failwith "process terminated without exiting; that shouldn't happen"
		| (Success, None) :: _ ->
			Printf.eprintf "ERROR: %s has never succeeded%s\n" desc (progress_desc progress);
			exit 1
		| (Success, Some diff) :: _ ->
			if diff > max_age then (
				Printf.eprintf "ERROR: %s hasn't succeeded for more than %s (last success: %s)\n"
					desc (string_of_time_diff max_age) (string_ago_of_time_diff diff);
				exit 1
			) else (
				(* All good *)
			)
		| (Progress, None) ::tail | (Error, None) :: tail -> loop ~progress tail
		| (Progress, Some diff) :: tail -> loop ~progress:(Some diff) tail
		| (Error, Some diff) :: _ ->
			Printf.eprintf "ERROR: %s failed %s%s\n" desc
				(string_ago_of_time_diff diff) (progress_desc progress);
			exit 1
	in

	fun statuses -> (
		let statuses = statuses
			|> List.sort (fun a b -> compare_time (snd a) (snd b))
			(* |> List.rev *)
		in
		if !verbose then statuses |> List.iter (fun (st, time) ->
			Printf.eprintf " - status `%s`: %s\n" (string_of_status st)
				(match time with None -> "never" | Some diff -> string_ago_of_time_diff diff)
		);
		loop ~progress:None statuses
	)

let snd (_,b) = b

let fetch ~dir ~now status =
	let open Unix in
	let status_str = string_of_status status in
	let path = Filename.concat dir status_str in
	let stats = try Some (stat path) with Unix_error (ENOENT, _, _) -> None in
	match stats with
		| None ->
				if !verbose then
					Printf.eprintf "%s not found\n" path;
				None
		| Some st ->
			let time = st.st_mtime in
			if time > now then (
				if !verbose then
					Printf.eprintf "%s mtime is in the future; ignoring\n" status_str;
				None
			) else (
				Some (now -. time)
			)

let () =
	let max_age = ref 0 in
	let desc = ref "job" in
	let dir = ref None in
	Arg.parse [
		("--max-age", Arg.String (fun age ->
			max_age := (match Str.full_split (Str.regexp "[0-9]+ ?") age with
				| [ Str.Delim num; Str.Text units ] ->
					let units = match units with
						| "s" | "second" | "seconds" -> 0
						| "m" | "minute" | "minutes" -> 60
						| "h" | "hour" | "hours" -> 60 * 60
						| "d" | "day" | "days" -> 60 * 60 * 24
						| other -> failwith ("Unknown units: " ^ other)
					in
					let num = int_of_string (String.trim num) in
					num * units
				| _other ->
					(* let open Str in *)
					(* _other |> List.iter (function *)
					(* 	| Delim d -> Printf.eprintf " - Delim %s\n" d *)
					(* 	| Text d -> Printf.eprintf " - Text %s\n" d *)
					(* ); *)
					failwith "invalid max-age format (must be \\d+[hmds])"
			)
		), "maximum age of last success");
		("--desc", Arg.Set_string desc, "job description (used in error messages)");
		("--verbose", Arg.Set verbose, "verbose logging");
	] (fun arg ->
		match !dir with
			| Some x -> failwith "too many arguments"
			| None -> dir := Some arg
	) "Usage: [OPTIONS] path/to/status";

	let dir = match !dir with
		| None -> failwith "directory required"
		| Some dir -> dir
	in
	let desc = !desc in
	let max_age = match !max_age with
		| 0 -> failwith "max-age required"
		| x -> x
	in

	let now = Unix.time () +. 1.0 in

	let statuses = status_types |> List.map (fun st -> (st, fetch ~dir ~now st)) in
	process ~desc ~max_age:(float_of_int max_age) statuses
