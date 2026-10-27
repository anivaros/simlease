"""Check that lifecycle authorization tests reject broken lease decisions."""
import test_lifecycle as lifecycle

original = lifecycle.SOURCE
mutations = [
    ("owner", 'and .owner == $owner', '', {"owner": "other"}),
    ("expiry", 'age >= ttl', 'age >= ttl + 99999', {"expired": True}),
]
for label, old, new, kwargs in mutations:
    assert old in original, f"mutation target missing: {label}"
    lifecycle.SOURCE = original.replace(old, new, 1)
    try:
        lifecycle.scenario(f"mutant {label}", **kwargs)
    except AssertionError:
        print(f"PASS {label} mutant detected")
    else:
        raise AssertionError(f"{label} mutant survived")
    finally:
        lifecycle.SOURCE = original
