# The usage gate. Input: the stream-json lines of
#   claude -p "/usage" --output-format stream-json --verbose
# read with `jq -s` (one array). Args: --arg session_max N --arg weekly_max N.
#
# On Claude Code 2.1.300 the limits sit at .usage_report.rate_limits.limits on
# the assistant message; older builds put them at .rate_limits on the system
# message. Both are looked at.
#
# Output: {open, session_pct, weekly_pct, resets_at, scoped_over, error}.
# resets_at is the earliest reset of the limits that are over (null when open).
# scoped_over lists the lower-cased model display names whose weekly_scoped
# limit is at or above weekly_max; they skip that model's tickets only.

def first_limits:
  [ .[]? | objects | (.rate_limits, .usage_report.rate_limits) | objects | .limits | arrays ]
  | first // null;

(try first_limits catch null) as $l
| if $l == null then
    {open: false, error: "no rate_limits in /usage output"}
  else
    ($l | map(select(.kind == "session")) | first) as $s
    | ($l | map(select(.kind == "weekly_all")) | first) as $w
    | if $s == null or $w == null or ($s.percent|type) != "number" or ($w.percent|type) != "number" then
        {open: false, error: "session or weekly_all limit missing from /usage output"}
      else
        ($s.percent >= ($session_max | tonumber)) as $s_over
        | ($w.percent >= ($weekly_max | tonumber)) as $w_over
        | {
            open: (($s_over or $w_over) | not),
            session_pct: $s.percent,
            weekly_pct: $w.percent,
            session_resets_at: $s.resets_at,
            weekly_resets_at: $w.resets_at,
            resets_at: ([ (if $s_over then $s.resets_at else empty end),
                          (if $w_over then $w.resets_at else empty end) ]
                        | map(select(. != null)) | sort | first // null),
            scoped_over: [ $l[]
                           | select(.kind == "weekly_scoped" and (.percent|type) == "number"
                                    and .percent >= ($weekly_max | tonumber))
                           | (.scope.model.display_name // "" | ascii_downcase)
                           | select(. != "") ],
            error: null
          }
      end
  end
