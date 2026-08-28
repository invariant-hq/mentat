`debug model` prints the model-conditioning decisions a run makes — the editor
family and the reasoning effort — with the model facts, offline and without
touching credentials.

  $ use_trusted_workspace

An explicit selector resolves through the catalog and reports its decisions.

  $ mentat debug model --model openai/gpt-5.6-sol | grep -o 'Model: openai/gpt-5.6-sol'
  Model: openai/gpt-5.6-sol
  $ mentat debug model --model openai/gpt-5.6-sol | grep -o 'editor: apply-patch'
  editor: apply-patch
  $ mentat debug model --model openai/gpt-5.6-sol | grep -o 'reasoning: medium'
  reasoning: medium

The JSON view carries the decisions under one envelope.

  $ mentat debug model --model openai/gpt-5.6-sol --json > model.json
  $ mentat_cram json .type model.json
  debug_model
  $ mentat_cram json .decisions.editor.value model.json
  apply-patch
  $ mentat_cram json .decisions.reasoning.value model.json
  medium

An unknown provider is a usage error (exit 2).

  $ mentat debug model --model bogus/nope 2>&1
  mentat: unknown provider "bogus"; known providers: openai, anthropic, google, local, ollama, opencode-go
  [2]
