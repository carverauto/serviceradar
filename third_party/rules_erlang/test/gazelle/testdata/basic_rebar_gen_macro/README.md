# Seshat

Seshat is a counters registry that maintains counter references with associated
meta data about what each counter refers to. Makes it easy to export counters
in a format suitable for external export to, e.g. [prometheus](https://prometheus.io/).

Seshat is a foundation for the future metrics subsystem in RabbitMQ.

## Project Maturity

Maturing.

## Documentation

### First create a new seshat group

A group in seshat is some logical partitioning of counters. E.g. you may have
a group per erlang application, or some subcomponent of your system.
```erlang 
GroupRef = seshat:new_group(pets),
```

A group is essentially en ETS table where counters and their meta data will be
stored. The `GroupRef` is an opaque type (but really it is an `ets:tid()`. The 
group can be any `term()` but it makes sense to just use atoms. Keep stuff tidy folks.

Now we're ready to register some counters. 
```erlang 
-define(C_CARROTS_EATEN, 1).
-define(C_HOLES_DUG, 2).
```
```erlang
Fields = [{carrots_eaten_total, ?C_CARROTS_EATEN, counter,
            "Total number of carrots eaten on a meal"},
          {holes_dug_total, ?C_HOLES_DUG, counter,
           "Total number of holes dug in an afternoon"}],
Name = rabbit,
CountersRef = seshat:new(pets, Name, Fields),
```

The `CountersRef` is a `counters:counters_ref()` type and can use used as usual
with the counters module. The `CountersRef` can be stored in the state of a
stateful erlang module or be retrieved using `sesaht:fetch(Group, Name)`
```erlang 
counters:add(CountersRef, ?C_CARROTS_EATEN, 3),
```
To inspect the counters on the system for a given group do:
```erlang
Overview = seshat:overview(pets),
```
Overview is a map of `#{Name => #{FieldName, Count}}`. E.g. for the above
it would look like:
```erlang 
#{rabbit => #{carrots_eaten_total => 3, holes_dug_total => 0}}
```

There is also `seshat:format(Groups)` which for the above case will return:
```erlang 
#{carrots_eaten_total =>
    #{help => "Total number of carrots eaten on a meal",
      type => counter,
      values => #{rabbit => 3}},
  holes_dug_total =>
    #{help => "Total number of holes dug in an afternoon",
      type => counter,
      values => #{rabbit => 0}}}
```


This format uses the counter `Name` as a unique value label for the metrics.
This formatting is more suitable for e.g. prometheus export. The counter name
doesn't have to be an atom. It can also be a list of two-tuples or
a pre-formatted binary.


## Copyright and License

(c) 2022, VMware Inc or its affiliates.

Double licensed under the ASL2 and MPL2.0.
See [LICENSE](./LICENSE) for details.
