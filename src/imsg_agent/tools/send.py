"""Execute a resolved send plan; never retry an uncertain submission automatically."""

from imsg_agent.messenger import MessengerError


def handle_send(args, messenger, store):
    results = []
    for item in args["items"]:
        try:
            result = messenger.send(item["to"], item["message"], service=item["service"])
        except MessengerError as exc:
            store.log_send(item["to"], item["message"], success=False, error=str(exc))
            results.append({"to": item["to"], "status": "unknown_or_failed", "error": str(exc)})
            break
        if result.status != "dry_run":
            store.log_send(item["to"], item["message"], success=True)
        results.append({"to": item["to"], **result.model_dump()})
    return {"results": results, "unattempted": len(args["items"]) - len(results)}
