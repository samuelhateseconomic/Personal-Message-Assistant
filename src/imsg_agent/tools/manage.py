"""Read schedules and cancel only pending entries."""


def handle_list(args, store):
    return {
        "schedules": [m.model_dump(mode="json") for m in store.list_schedules(args.get("status"))]
    }


def handle_cancel(args, store):
    if not store.cancel_pending(args["id"]):
        return {"error": "Schedule is missing or is no longer pending"}
    return {"status": "cancelled", "id": args["id"]}
