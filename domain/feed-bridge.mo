## Isolated bridge providing a default `Modb.Policy.SensitivityPolicy` for `Modb.Feeds`
## without colliding with `Domain.Policy` in modules that import both.
module Domain.FeedBridge
expose empty_sensitivity_policy
use Modb.Policy

## Returns an empty `Modb.Policy.SensitivityPolicy` permitting non-restricted buckets.
fn empty_sensitivity_policy() : Policy.SensitivityPolicy
  Policy.policy()
end
