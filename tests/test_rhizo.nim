import unittest
import rhizo

suite "rhizo":
  test "hello returns expected greeting":
    check hello() == "hello from rhizo"

  test "version present":
    check projectVersion == "0.0.1"
