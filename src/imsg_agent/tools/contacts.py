"""Structured contact retrieval with identity gating and field provenance."""


def handle_resolve(args, contact_manager):
    result = contact_manager.resolve(args["query"])
    if result.status != "resolved":
        return {
            "status": result.status,
            "needs_clarification": True,
            "candidates": [{"name": c.name, "phone": c.phone} for c in result.candidates],
        }
    contact = result.contact
    stored = next(
        (
            i
            for i, c in enumerate(contact_manager.contacts)
            if c.name == contact.name and c.phone == contact.phone
        ),
        None,
    )
    if stored is None:
        return {
            "status": "resolved",
            "contact": {"name": contact.name, "phone": contact.phone},
            "sources": [],
            "evidence": "User-supplied phone only; no stored personal facts",
        }
    facts = contact.model_dump()
    unknown_fields = []
    for field in ("timezone", "service"):
        if (
            field not in contact.model_fields_set
            or contact.metadata.get(field + "_verified") is False
        ):
            facts.pop(field, None)
            unknown_fields.append(field)
    facts["unknown_fields"] = unknown_fields
    facts["metadata"] = {k: v for k, v in contact.metadata.items() if k != "contact_imports"}
    # Preserve useful imported fields without flooding the model with raw vCards.
    properties = []
    for record in contact.metadata.get("contact_imports", []):
        for prop in record.get("vcard_properties", []):
            if (
                prop["property"] in ("EMAIL", "ADR", "BDAY", "ORG", "TITLE", "NOTE")
                and prop not in properties
            ):
                properties.append(prop)
    facts["metadata"]["imported_facts"] = properties
    return {
        "status": "resolved",
        "contact": facts,
        "sources": [f"{contact_manager.path.name}#/contacts/{stored}"],
        "evidence": "Stored contact fields only; missing facts are unknown",
    }


def handle_list_contacts(args, contact_manager):
    contacts = (
        contact_manager.get_group(args["group"]) if args.get("group") else contact_manager.contacts
    )
    return {"contacts": [{"name": c.name, "phone": c.phone, "group": c.group} for c in contacts]}
