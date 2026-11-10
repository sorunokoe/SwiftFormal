"""Controlled source variants; the approved discount contract is never rewritten."""

from textwrap import dedent, indent


ORIGINAL = """public func clampedDiscount(_ subtotal: Int64, _ discount: Int64) -> Int64 {
    if discount > subtotal {
        return 0
    }
    return subtotal - discount
}"""


def fixture(original, body):
    selected, separator, rest = original.partition("\n\n")
    if selected != ORIGINAL or not separator:
        raise ValueError("The original selected function changed")
    return (
        ORIGINAL.split("\n", 1)[0] + "\n" + indent(dedent(body).strip(), "    ")
        + "\n}\n\n" + rest
    )


def ordinary():
    return {
        "original": """
            if discount > subtotal {
                return 0
            }
            return subtotal - discount
        """,
        "guard": """
            guard discount < subtotal else {
                return 0
            }
            return subtotal - discount
        """,
        "early-return": """
            if discount < subtotal {
                return subtotal - discount
            }
            return 0
        """,
        "joined": """
            let result: Int64 = if discount > subtotal {
                0
            } else {
                subtotal - discount
            }
            return result
        """,
        "reused": """
            if discount > subtotal {
                return 0
            }
            let result = subtotal - discount
            if result < 0 {
                return 0
            }
            return result
        """,
    }


def wrong_returns():
    return {
        "wrong-guard-return": """
            guard discount < subtotal else {
                return 0
            }
            if subtotal < 50 {
                return subtotal
            }
            return subtotal - discount
        """,
        "wrong-joined-return": """
            let result: Int64 = if discount > subtotal {
                0
            } else {
                subtotal - discount
            }
            if subtotal < 50 {
                return subtotal
            }
            return result
        """,
    }


def diamonds(count):
    if count not in (1, 2, 4, 8):
        raise ValueError("The growth experiment uses 1, 2, 4, or 8 diamonds")
    lines = []
    previous = "discount"
    for index in range(count):
        name = f"discount{index}"
        lines.extend([
            f"let {name}: Int64 = if subtotal < discount {{",
            f"    {previous}",
            "} else {",
            f"    {previous}",
            "}",
        ])
        previous = name
    lines.extend([
        f"if {previous} > subtotal {{",
        "    return 0",
        "}",
        f"return subtotal - {previous}",
    ])
    return "\n".join(lines)


def extra_syntax():
    return {
        "guard-greater-equal": """
            guard subtotal >= discount else {
                return 0
            }
            return subtotal - discount
        """,
        "deferred-initialization": """
            let result: Int64
            if discount > subtotal {
                result = 0
            } else {
                result = subtotal - discount
            }
            return result
        """,
    }
