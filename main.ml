let verbose = ref false

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

type result = Ok | Error of string option
type pid = int
type progress = Running of pid option

type 'a status = {
	age: float;
	result: 'a;
}

let parse_pid = fun str ->
	Running (
		try Some (int_of_string (String.trim str))
		with Failure _ -> None
	)

let parse_result = fun str ->
	let space = Str.regexp "[ \t\n]+" in
	match Str.bounded_split space str 2 with
		| "ok" :: _ -> Ok
		| ["error"] -> Error None
		| ["error"; msg] -> Error (Some (String.trim msg))
		| [] -> Error (Some ("Status file is empty"))
		| status :: _ -> Error (Some
			(Printf.sprintf "Couldn't parse status file: unknown status \"%s\"" status)
		)

let read_file path =
	(* NOTE: only reads up to 1kb *)
	let open Unix in
	let fd = openfile path [O_RDONLY] 0x000 in
	let buflen = 1024 in
	let buf = Bytes.create buflen in
	let len = read fd buf 0 buflen in
	(fstat fd, Bytes.sub buf 0 len |> Bytes.to_string)

let read_status ~now path parse =
	let open Unix in
	let contents = try Some (read_file path) with Unix_error (ENOENT, _, _) -> None in
	match contents with
		| Some (stat, contents) ->
			let time = stat.st_mtime in
			if time > now then (
				if !verbose then
					Printf.eprintf "WARN: mtime is in the future; ignoring %s\n" path;
				None
			) else
				Some { age = now -. time; result = parse contents }
		| None ->
			if !verbose then Printf.eprintf "%s not found\n" path;
			None

let write_file_contents ~path str =
	let f = open_out path in
	output_string f str;
	close_out f

let maxbytes = 1024

let read_tee fd buf =
	let n = Unix.read fd buf 0 maxbytes in
	let str = Bytes.sub_string buf 0 n in
	if n > 0 then output_string stdout str;
	str

let rec drain fd buf =
	if read_tee fd buf <> "" then drain fd buf

let rec waitpid_with_retry flags pid =
	let open Unix in
	try waitpid flags pid
	with Unix_error (EINTR, _, _) -> waitpid_with_retry flags pid

let run ~path cmd =
	let exe = match cmd with
		| [] -> failwith "Command required"
		| (exe :: _) -> exe
	in
	(* Printf.printf "exec: %s\n" (String.concat " " cmd); *)
	let open Unix in
	let r,w = pipe ~cloexec:false () in
	let pid = fork () in
	let pid_path = path ^ ".pid" in
	if pid = 0 then (
		(* child process: write pid file and run *)
		close r;
		dup2 ~cloexec:false w stderr;
		close w;
		let pid = getpid () in
		write_file_contents ~path:pid_path (string_of_int pid);
		(* replace stderr with the writeable end of the socket *)
		execvp exe (Array.of_list cmd)
	) else (
		(* parent process *)
		let (status, stderr_contents) = try (
			close w;
			let buf = Bytes.make maxbytes ' ' in
			let stderr_contents = read_tee r buf in
			drain r buf;
			(* TODO update PID file occasionally? *)
			let (_pid, status) = waitpid_with_retry [WUNTRACED] pid in
			(status, stderr_contents)
		) with e -> (
			write_file_contents ~path "error aborted";
			raise e
		) in
		match status with
			| WEXITED 0 -> write_file_contents ~path "ok"
			| _ -> (
				write_file_contents ~path ("error " ^ stderr_contents);
				exit (match status with WEXITED n -> n | _ -> 1)
			)
	)

let check ~desc ~max_age path =
	let desc = !desc in
	let max_age = match !max_age with
		| 0 -> failwith "max-age required"
		| x -> x
	in

	let now = Unix.time () +. 1.0 in
	let red = "\027[31;1m" in
	let dim = "\027[33;1m" in
	let reset = "\027[0m" in
	let join = String.concat "" in

	let error = join [red; "ERROR: "; reset] in
	let error_msg s = s in

	let status = read_status ~now path parse_result in
	let progress () = read_status ~now (path ^ ".pid") parse_pid in
	let progress_desc ~result_age () = match progress () with
		| None -> ""
		| Some { age; result } ->
			let is_old = match result_age with
				| Some result_age -> result_age < age
				| None -> false
			in
			if is_old then "" else (
				let pid_desc = match result with
					| Running (Some pid) -> Printf.sprintf ", pid %d" pid
					| Running None -> ""
				in
				join [
					dim;
					" (process active ";
					string_ago_of_time_diff age;
					pid_desc;
					")";
					reset;
				]
			)
	in

	let max_age = float_of_int max_age in
	match status with
		| None ->
			prerr_endline (join [
				error;
				error_msg (join [desc; " has no recorded results" ]);
				progress_desc ~result_age:None ()
			]);
			exit 1
		| Some { result = Ok; age } ->
			if age > max_age then (
				prerr_endline (join [
					error;
					error_msg (join [
						desc;
						" hasn't succeeded for more than ";
						string_of_time_diff max_age;
						progress_desc ~result_age:(Some age) ();
						".";
					]);
					" Last success: "; (string_ago_of_time_diff age);
				]);
				exit 1
			) else (
				(* All good *)
			)
		| Some { result = Error err; age } ->
			prerr_endline (join [
				join [red; "ERROR ("; desc; ", "; string_ago_of_time_diff age; "): "; reset];
				error_msg (match err with Some e -> e | None -> "failed");
				".";
				progress_desc ~result_age:(Some age) ();
			]);
			exit 1

type run_mode = Check | Run of string list

let () =
	let max_age = ref 0 in
	let desc = ref "job" in
	let path = ref None in
	let mode = ref Check in
	let string_opt ref = fun value -> ref := Some value in
	let add_positional_arg = fun arg ->
		match !mode with
			| Check -> (
				match !path with
					| Some x -> failwith "too many arguments"
					| None -> path := Some arg
			)
			| Run cmd -> mode := Run (cmd @ [arg])
	in
	Arg.parse [
		("--run", Arg.Unit (fun () ->
			mode := Run [];
			let max = Array.length Sys.argv in
			let rec iter = function i ->
				if i < max then (
					add_positional_arg (Array.get Sys.argv i);
					iter (i+1)
				)
			in
			iter (!Arg.current + 1);
			Arg.current := max
		), "Remaining arguments are treated as a command to run. " ^
		   "pid and result files are automatically written, and the contents of stderr " ^
		   "will be reported as the error message on failure.");
		("-f", Arg.String (string_opt path), "status file path");
		("--max-age", Arg.String (fun age ->
			max_age := (match Str.full_split (Str.regexp "[0-9]+ ?") age with
				| [ Str.Delim num; Str.Text units ] ->
					let units = match units with
						| "s" | "second" | "seconds" -> 1
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
	] add_positional_arg "Usage: [OPTIONS] path/to/status";

	let path = match !path with
		| None -> failwith "path required"
		| Some path -> path
	in

	match !mode with
		| Check -> check ~desc ~max_age path
		| Run cmd -> run ~path cmd
