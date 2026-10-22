# Projects what GitHub stored onto the shape of what we asked for, so fields GitHub fills with defaults do not count
# as a difference, while a rule, a value or a key we did not ask for still does (a pinned sha, an extra condition, a
# reviewer requirement, a bypass actor). Only keys that are metadata or hold a trivial value are ignored.

def trivial:
    . == null or . == false or . == "" or . == [] or . == {}
    or (type == "object" and (to_entries | all(.value | trivial)));

def metadata:
    ["id", "node_id", "source_type", "source", "created_at", "updated_at", "_links", "current_user_can_bypass",
     "require_extra_approval_for_unattributed_changes"];

def shape($wanted):
    . as $stored
    | if ($wanted | type) == "object" and ($stored | type) == "object" then
        (reduce ($wanted | keys[]) as $key ({}; .[$key] = ($stored[$key] | shape($wanted[$key]))))
        + ([$stored | to_entries[]
            | select((.key | IN($wanted | keys[]) | not) and (.key | IN(metadata[]) | not) and (.value | trivial | not))
            | {("unexpected key: " + .key): .value}] | add // {})
    elif ($wanted | type) == "array" and ($stored | type) == "array" then
        [range(0; ($wanted | length)) as $i | $stored[$i] | shape($wanted[$i])]
        + (if ($stored | length) > ($wanted | length) then ["unexpected extra entry"] else [] end)
    else
        $stored
    end;

($wanted | .rules |= sort_by(.type)) as $target
| (.rules |= sort_by(.type))
| shape($target)
