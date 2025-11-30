# FZ - A Fuzzy Finder

Highly based on [fzy](https://github.com/jhawthorn/fzy/tree/master) and 
uses the same algorithm to find matches.


## Usage

```sh
# interactive
find . -type f | fz

# filter 
fz --filter needle < find . -type f
```

## Building from source

```sh
# use the same zig version as in build.zig.zon
zig build -Doptimize=ReleaseFast
```

## TODO

- [x] improve performance on large item sets
- [] minimize memory usage on large item sets
- [ ] decouple UI from search
- [ ] fzf like preview
- [x] default command to run from env

