# status-check

A dirt-simple program which monitors the state of arbitrary jobs, and gets in your face when they have failed (or haven't succeeded recently enough for your liking).

### Why would I want that?

Let's say you have a backup script. You've configured it all to run, via `cron`, or `systemd`, or something fancier. That system probably works, but do you have notifications for when the job (or the system which runs it) stops working because of some logic error or just a dumb configuration issue?

You could use any number of server monitoring tools, but those are very involved and require even more infrastructure. And what are they going to do, send you emails? SMS you? That's probably more complex than your periodic task was in the first place - what if those things are misconfigured too?

I wanted a tool so stupidly simple that it couldn't _possibly_ give me false positives. This is that tool.

## Learn by example:

```
$ status-check --max-age 2d status
ERROR: job has no recorded results

$ echo 'something' > status
$ status-check --max-age 2d status
ERROR (job, 5 seconds ago): Couldn't parse status file: unknown status "something"

$ echo 'ok' > status
$ status-check --max-age 2s status
# (blissful silence)

# wait 30 seconds
$ status-check --max-age 2s status
ERROR: job hasn't succeeded for more than 2 seconds. Last success: 30 seconds ago

# wait another minute or two
$ echo $$ > status.pid
$ status-check --max-age 2s status
ERROR: job hasn't succeeded for more than 2 seconds (process active 2 seconds ago, pid 14430). Last success: 2 minutes ago

$ echo 'error' > status
$ status-check --max-age 2s status
ERROR (job, 2 seconds ago): failed.

$ echo 'error something went awry' > status
$ status-check --max-age 2s status
ERROR (job, 1 second ago): something went awry.

$ echo $$ > status.pid
$ status-check --max-age 2s status
ERROR (job, 18 seconds ago): something went awry. (process active 9 seconds ago, pid 4074)
```

## Where do you call it from?

Where do you _want_ to call it from? Basically, it should be somewhere where the errors will be in your face. I put it in my shell startup file, but I chose to only call it if `stdin` is a tty (to prevent it messing up automated scripts).

In bash / zsh, that's:

```
if [ -t 0 ]; then
  status-check --max-age "2 days" --desc "daily backup" ~/path/to/statusfile
fi
```

fish-shell users:

```
if isatty stderr
  status-check --max-age "2 days" --desc "daily backup" ~/path/to/statusfile
end
```

## Can't you integrate into my shell automatically?

..but if I did that, how would you be confident it's working? If you put it where all your other shell startup stuff goes, you'll be confident that it's actually running.

(also I'm way too lazy to write that kind of integration, I've tried and it sucks)

## How slow is it?

Super freakin' fast. It's just a couple of `stat()` and `read()` calls. `time` claims it takes about 4 milliseconds, and my machine is not even very fast. You could call it every time you render your shell prompt and you wouldn't notice the difference.

## What do the status file(s) look like?

As illustrated in the example above, a job should:

1. On success: write `ok` to the status file.

2. On error, write `error` to the status file. This can be followed by a space character and some error message which will be shown to the user. e.g. `error oh noes`

3. To indicate that a job is doing something (at startup, and potentially periodically throughout to indicate it's still alive), it can optionally write its PID to `<status-file>.pid`.

The modification time of the status / pid files will be used to determine what the most recent state of your job is.

That's all.

## Can you write the status file for me?

Sure, if you're happy with some defaults. Run `status-check -f PATH --run some-command -xyz foo` to execute `some-command -xyz foo` with additional tracking:

 - Before executing, the `pid` status file is written.
 - If the process exits with a zero exit status, `ok` is written to the status file.
 - If the process is killed or exits unsuccessfully, `error` is written, along with any output that was written to standard error.

## Compilation

You'll need ocaml, ocamlfind and ocamlbuild.

```
make
./install.sh /path/to/destination/prefix
```
