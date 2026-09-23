"""Persist an entire expanded schedule batch atomically."""

from imsg_agent.models import ScheduledMessage


def handle_schedule(args, store):
    messages = [
        ScheduledMessage(
            delivery_approved=True,
            **{
                k: v
                for k, v in item.items()
                if k in ScheduledMessage.model_fields and k != "delivery_approved"
            },
        )
        for item in args["items"]
    ]
    store.add_many(messages)
    return {
        "status": "scheduled",
        "ids": [m.id for m in messages],
        "notice": "Approved for background delivery when the daemon is running.",
    }
