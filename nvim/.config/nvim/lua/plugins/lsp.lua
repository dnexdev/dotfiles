return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      inlay_hints = {
        enabled = false,
      },
      servers = {
        clangd = {
          -- use the system clangd (/usr/bin/clangd) instead of mason's
          mason = false,
          cmd = {
            "clangd",
            "--background-index",
            "--clang-tidy",
            "--header-insertion=iwyu",
            "--completion-style=detailed",
            "--function-arg-placeholders",
            "--fallback-style=llvm",
            "--query-driver=/usr/bin/gcc,/usr/bin/g++,/usr/bin/clang++,/opt/homebrew/bin/*",
            "--experimental-modules-support",
          },
        },
        qmlls = {
          -- Arch ships qmlls (qt6-declarative) outside of PATH
          mason = false,
          cmd = {
            vim.fn.executable("qmlls") == 1 and "qmlls" or "/usr/lib/qt6/bin/qmlls",
          },
        },
        lua_ls = {
          settings = {
            Lua = {
              workspace = {
                -- hyprland lua stubs (only added if present on this system)
                library = vim.tbl_filter(function(p)
                  return vim.fn.isdirectory(p) == 1
                end, {
                  "/run/current-system/sw/share/hypr/stubs",
                  "/usr/share/hypr/stubs",
                }),
                checkThirdParty = false,
              },
              diagnostics = {
                globals = { "hl" },
              },
            },
          },
        },
      },
    },
  },
}
