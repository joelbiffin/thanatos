# Thanatos

[Thanatos](https://en.wikipedia.org/wiki/Thanatos) was the Ancient Greek's personification of death itself. It's not all doom and gloom though. This ruby project aims to personify death in a helpful way. Identifying code that has no references in your codebase - aka safe to delete! 

Whether code is safe to delete or not is a bit of a murky question in Ruby - especially in untyped Ruby. Fear not though, as dangling unused methods are a pretty safe place to start deleting things. Let's start there and see where we get to.

## Installation

> This is not a released gem, and it might never be. But feel free to clone away.


## Development

### Checklist

Please note that this checklist is ordered and maintained by me, based on the things I'm interested in and what areas I think will be most valuable to focus on short-term. Who knows if I'll still be doing this project in the next few months.

#### Parsing a single file

- Building a list of method declarations
- Building a list of internal method calls
- Handling multiple namespaces per file (and supporting the above)
- Distinguishing between internal and external method calls

### Requirements

At the moment, this is a personal project, so I will not make any effort to abide by backward-compatability of Ruby pre-3.x - sorry. Pull requests are always welcome though.


## Contributing

No ceremony, just raise Issues when you have questions / feature requests, but Pull Requests are better! At present, I am doing this work as a side project, so please treat it that way. The more helpful and engaged the feedback is, the more likely I am to focus more time on this project.



