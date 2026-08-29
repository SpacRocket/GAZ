// Remote console — what `bin/gaz qcon` actually runs.
//
// KDB-X 5.0 ships only bin/q; there is no qcon binary on the host or in the
// image, so `bin/gaz qcon` had nothing to exec. This is the replacement in
// plain q: .z.pi is the session input handler, so overriding it sends whatever
// you type to the remote process and prints what comes back.
//
//   q code/tools/rconsole.q localhost:6002
//   bin/gaz qcon rdb1
//   qcon rdb1                    (the env.sh helper)
//
// Three things learned the hard way, all of them load-bearing:
//
//   * .z.pi hands over the trailing newline, and q's `trim` strips spaces but
//     NOT newlines. Miss that and `\\` never matches the guard below, gets
//     forwarded, and means "exit q" on the far side — closing your console
//     kills the process you were inspecting. It did exactly that in testing.
//   * `exit` is ordinary input as far as .z.pi is concerned, so it is refused
//     here for the same reason.
//   * A handle held open keeps q's event loop alive, so Ctrl-D hangs instead
//     of exiting. Hence one connection per command rather than a persistent
//     one; at human typing speed the cost is irrelevant, and it means the
//     console also survives the far side restarting underneath it.

if[0=count .z.x;
  -2 "usage: q rconsole.q <host:port>  (e.g. localhost:6002)";
  exit 1];

\d .rc

target:hsym `$":",.z.x 0;

// Returns (1b;result) or (0b;error string).
call:{[expr]
  h:@[hopen; (target;5000); {[e] `err`msg!(1b;"cannot connect: ",e)}];
  if[99h=type h; :(0b;h`msg)];
  r:@[{(1b;x y)}h; expr; {(0b;x)}];
  @[hclose; h; ::];
  r }

send:{[x]
  x:trim x except "\r\n";
  if[not count x; :(::)];
  if[x~"\\\\"; -1 "closing"; exit 0];
  if[any x like/: ("exit";"exit *");
    -2 "refused: `exit` would terminate the remote process — use \\\\ to leave";
    :(::)];
  r:call x;
  $[first r; show last r; -2 "'",last r];
  (::) }

\d .

.rc.who:.rc.call "(string .proc.procname;string .proc.proctype)";
-1 $[first .rc.who;
     "connected to ",(" (" sv last .rc.who),") on ",1_string .rc.target;
     "cannot reach ",(1_string .rc.target),": ",last .rc.who];
if[not first .rc.who; exit 1];
-1 "\\\\ to exit";

.z.pi:.rc.send;
