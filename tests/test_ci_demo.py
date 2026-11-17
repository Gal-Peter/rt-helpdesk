def test_ci_catches_failures():
    assert 1 == 2, "deliberate failure to prove CI goes red"
