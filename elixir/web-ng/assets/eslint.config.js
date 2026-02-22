export default [
  {
    ignores: [
      "node_modules/**",
      "vendor/**",
      "../priv/static/**",
    ],
  },
  {
    files: ["js/**/*.js"],
    languageOptions: {
      ecmaVersion: "latest",
      sourceType: "module",
      globals: {
        window: "readonly",
        document: "readonly",
        console: "readonly",
        navigator: "readonly",
        MutationObserver: "readonly",
        URLSearchParams: "readonly",
        Event: "readonly",
        performance: "readonly",
        fetch: "readonly",
        requestAnimationFrame: "readonly",
        cancelAnimationFrame: "readonly",
        setTimeout: "readonly",
        clearTimeout: "readonly",
        setInterval: "readonly",
        clearInterval: "readonly",
        DataView: "readonly",
        ArrayBuffer: "readonly",
        Buffer: "readonly",
        Blob: "readonly",
        WebAssembly: "readonly",
        process: "readonly",
        atob: "readonly",
      },
    },
    rules: {
      "no-undef": "error",
      "no-unused-vars": [
        "error",
        {
          "argsIgnorePattern": "^_",
          "varsIgnorePattern": "^_",
          "caughtErrorsIgnorePattern": "^_"
        }
      ],
    },
  },
]
