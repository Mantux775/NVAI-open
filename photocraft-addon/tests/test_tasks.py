from bridge.tasks import Task, Variant


def test_task_public_is_json_ready_and_has_urls():
    t = Task(id="x", mode="fill", prompt="", params={"mode": "fill"})
    t.variants.append(Variant(index=0, file="jobs/x/result-1.png", thumb="jobs/x/thumb-1.png", caption="c"))
    d = t.public()
    assert "cancel_event" not in d
    assert d["variants"][0]["url"] == "/jobs/x/result-1.png"
    assert d["variants"][0]["caption"] == "c"
    assert d["mode_label"] == "Fill"
