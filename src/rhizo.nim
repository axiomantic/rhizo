# rhizo - Production-grade project built with Axiomantic standards.

const projectVersion* = "0.0.1"

const greetingMsg* = "hello from rhizo"

proc hello*(): string =
  ## Returns standard project greeting string.
  greetingMsg

proc add*(a, b: int): int =
  ## Adds two integers.
  a + b
