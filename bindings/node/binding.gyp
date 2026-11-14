{
  "targets": [
    {
      "target_name": "rill_node",
      "sources": ["src/addon.c"],
      "include_dirs": ["../../include"],
      "library_dirs": ["../../build"],
      "libraries": ["-lrill"],
      "ldflags": ["-Wl,-rpath,<!(pwd)/../../build"]
    }
  ]
}
