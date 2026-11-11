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

-- External skill: the repository is the source of truth. This loader only
-- syncs the files Maki's skill tool reads into the local skills directory, so
-- maki-config never vendors the skill itself.
local function sync_external_skill(pkg)
    local src = pkg.path
    if not src then
        maki.log.warn("stress-test-user-feature: package path unavailable")
        return
    end

    local config = maki.env.config_dir()
    if not config then
        maki.log.warn("stress-test-user-feature: config dir unavailable")
        return
    end

    local dest = maki.fs.joinpath(config, "skills", "stress-test-user-feature")
    local _, mkdir_err = maki.fs.mkdir(dest, { parents = true })
    if mkdir_err then
        maki.log.warn("stress-test-user-feature: mkdir failed: " .. tostring(mkdir_err))
        return
    end

    local files = { "SKILL.md" }
    local refs = maki.fs.dir(maki.fs.joinpath(src, "references"))
    if refs then
        local ref_dest = maki.fs.joinpath(dest, "references")
        local _, ref_err = maki.fs.mkdir(ref_dest, { parents = true })
        if ref_err then
            maki.log.warn("stress-test-user-feature: references mkdir failed: " .. tostring(ref_err))
        else
            for _, entry in ipairs(refs) do
                if entry[2] == "file" then
                    files[#files + 1] = "references/" .. entry[1]
                end
            end
        end
    end

    for _, rel in ipairs(files) do
        local content, read_err = maki.fs.read(maki.fs.joinpath(src, rel))
        if not content then
            maki.log.warn("stress-test-user-feature: read " .. rel .. " failed: " .. tostring(read_err))
        else
            local _, write_err = maki.fs.write(maki.fs.joinpath(dest, rel), content)
            if write_err then
                maki.log.warn("stress-test-user-feature: write " .. rel .. " failed: " .. tostring(write_err))
            end
        end
    end
end

maki.pack.add({
    {
        src = "https://github.com/Anhydrite/stress-test-user-feature",
        name = "stress-test-user-feature",
        version = "main",
    },
}, {
    confirm = false,
    load = sync_external_skill,
})

require("ocgo")
require("tps")
require("autocompact").setup({ percent = 30, resume = true })
require("relance")
require("jobs")
require("handoff")
