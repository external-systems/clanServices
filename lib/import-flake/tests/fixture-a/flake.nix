{
  description = "Fixture A: depends on B";

  inputs.b = {
    url = "path:../fixture-b";
    flake = true;
  };

  outputs =
    { self, b }:
    {
      greeting = "hello from a";
      # This forces b — but only b.greeting, not b.aGreeting, so no infinite loop.
      bGreeting = b.greeting;
    };
}
