# v6: the words travel with the block

v5 was the first measure of the chat with display tools (a record card, figures, a chart, a work
list, a form, a draft, a comparison, a timeline) and a `suggest_next_questions` tool. It scored
67 of 84. Thirteen of the seventeen failures had one cause: Claude called a display tool, or only
the follow-up tool, before writing anything, expecting a turn afterwards to write the answer. A
turn of display calls is final, so the answer's sentence was never written.

Changed:

- Every display tool now starts with `say`, the one or two sentences shown above the block. The
  words are part of the call, so they cannot be left for a turn that never comes.
- Follow-up questions are no longer a tool. They are lines starting with `?>` at the end of the
  words, which Apex takes off and returns as the block of buttons. A plain answer stays a plain
  end of turn.
- Prompt: summarizing the open record is words, not a redraw of its page; `say` names the count,
  total or full name that was asked for.
- Tool text: a work list of more than eight gives the full count in `say`; a timeline holds only
  what has happened; a form's button is named.
- The draft block's `kind` (email or letter) became `format`, which the eval's own `kind` was
  overwriting.
- Eval check `saysNotDone` no longer trips on "I've set up a form".
