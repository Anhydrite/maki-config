maki.setup({
    always_yolo = true,
    agent = {
        -- Native auto-compaction trigger (context_window - buffer). The buffer
        -- is capped at 50% of the window, so this is the earliest native
        -- trigger, kept as a backstop; lua/autocompact.lua compacts at 30%.
        compaction_buffer = "50%",
    },
    ui = {
        -- "auto" detects WezTerm and sends OSC 9. WezTerm turns those into
        -- "persistent" critical notifications (expire_timeout=0, urgency=2),
        -- which COSMIC never auto-dismisses, and WezTerm has no config option
        -- to add a timeout. "notify" goes through the desktop notification
        -- daemon instead, so the compositor's timeout applies and the toast
        -- disappears on its own.
        notifications = "notify",
    },
})

require("ocgo")
require("tps")
require("autocompact").setup({ percent = 30 })
