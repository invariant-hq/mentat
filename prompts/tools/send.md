Send a message to a related agent session: one of your spawned children
(to: "child:<id>") or, if you are a spawned child yourself, your parent
(to: "parent"). The message lands durably in the target's queue, attributed
to you, and is read at the target's next turn boundary; it never interrupts
a turn already running and never starts one on an idle session. Message a
running child to steer it mid-run — add a constraint, answer a question it
asked — and message your parent to report progress or hand back a result
before you settle. To start a fresh turn on a child that has gone idle, use
follow_up instead.
