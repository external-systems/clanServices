{
  description = "Fixture B: depends on A";

  inputs.a = {
    url = "path:../fixture-a";
    flake = true;
  };

  outputs =
    { self, a }:
    {
      greeting = "hello from b";
      # This forces a — but only a.greeting, not a.bGreeting, so no infinite loop.
      aGreeting = a.greeting;
    };
}
