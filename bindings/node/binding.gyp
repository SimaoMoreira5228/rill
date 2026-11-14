{
  "targets": [
    {
      "target_name": "rill_node",
      "sources": ["src/addon.c"],
      "include_dirs": ["native-src/include", "../../include"],
      "library_dirs": ["<!@(node scripts/libdir.js)"],
      "libraries": ["<!@(node scripts/lib.js)"],
      "conditions": [
        [
          "OS=='linux'",
          {
            "ldflags": [
              "-Wl,-rpath,'$$ORIGIN'",
              "-Wl,-rpath,<!(node scripts/libdir.js)"
            ]
          }
        ],
        [
          "OS=='mac'",
          {
            "ldflags": [
              "-Wl,-rpath,@loader_path",
              "-Wl,-rpath,<!(node scripts/libdir.js)"
            ]
          }
        ]
      ]
    }
  ]
}
