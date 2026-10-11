"""backend_appkit.py: the decisions, asserted on a platform with no menu bar.

THE POINT OF THIS FILE IS THAT IT DOES NOT SKIP. backend_dbus's tests skip
without dbus_next and say in their own header why that is tolerable: the
SHARED half lives in test_sni.py, so a skip costs nothing. The macOS backend
has a third category, which is logic that is neither shared nor wire: reusing
a notification identifier so UN REPLACES rather than stacks, and withdrawing
from BOTH the delivered and the pending list. Those are decisions, and the
backend defers every AppKit import precisely so they are reachable here.

WHAT IS LEFT UNREACHABLE IS NAMED RATHER THAN SKIPPED QUIETLY: `export`,
`_pump` and `_nsimage` need a real AppKit, so they are verified by
test/macos-probe on a runner instead, which measured the status item drawing
at (645,8)-(866,22) and the run loop pumping 40 slices without starving
asyncio. A skip here would have read as "macOS is untested" and the honest
statement is narrower than that.
"""
import asyncio
import sys
import types
import unittest

import mux_desktop_notifier.backend_appkit as backend
import mux_desktop_notifier.sni as sni


def run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


class FakeCentre:
    """A UNUserNotificationCenter that records instead of notifying.

    DUCK-TYPED, which is the same property that lets `Toaster` be asserted
    against a fake bus: the centre is handed in as `bus`, so nothing here
    needs a Mac. `err` is what the completion handler reports, because an
    unauthorized daemon is the COMMON case until somebody grants a permission
    and a probe that could not see the refusal already fooled us once.
    """

    def __init__(self, err=None):
        self.added = []
        self.delivered_removed = []
        self.pending_removed = []
        self.err = err

    def addNotificationRequest_withCompletionHandler_(self, req, handler):
        self.added.append(req)
        if handler is not None:
            handler(self.err)

    def removeDeliveredNotificationsWithIdentifiers_(self, idents):
        self.delivered_removed.append(list(idents))

    def removePendingNotificationRequestsWithIdentifiers_(self, idents):
        self.pending_removed.append(list(idents))


class _Content:
    def __init__(self):
        self.title = None
        self.body = None

    def setTitle_(self, t):
        self.title = t

    def setBody_(self, b):
        self.body = b


class _Request:
    def __init__(self, ident, content):
        self.ident = ident
        self.content = content


def fake_un():
    """The UserNotifications module, as much of it as `_raise` touches."""
    mod = types.ModuleType("UserNotifications")

    class UNMutableNotificationContent:
        @staticmethod
        def alloc():
            return UNMutableNotificationContent()

        def init(self):
            return _Content()

    class UNNotificationRequest:
        @staticmethod
        def requestWithIdentifier_content_trigger_(ident, content, trigger):
            return _Request(ident, content)

    mod.UNMutableNotificationContent = UNMutableNotificationContent
    mod.UNNotificationRequest = UNNotificationRequest
    return mod


class Raising(unittest.TestCase):
    """What `_raise` does with an identifier, which is the whole of replacing.

    THE IDENTIFIER IS THE MECHANISM on this platform: freedesktop replaces by
    passing the previous numeric id to Notify, and UN replaces by reusing the
    string. Get it wrong and a session that blocks, is answered and blocks
    again leaves a COLUMN of banners, which is the failure the id map exists
    to prevent on both platforms.
    """

    def setUp(self):
        sys.modules["UserNotifications"] = fake_un()
        self.centre = FakeCentre()
        self.t = backend.toaster(self.centre)

    def tearDown(self):
        sys.modules.pop("UserNotifications", None)

    def test_a_first_raise_mints_an_identifier(self):
        ident = run(self.t._raise(None, "sum", "body"))
        self.assertTrue(ident)
        self.assertEqual([ident], [r.ident for r in self.centre.added])

    def test_a_replacement_REUSES_the_previous_identifier(self):
        first = run(self.t._raise(None, "sum", "body"))
        again = run(self.t._raise((first, "blocked"), "sum2", "body2"))
        self.assertEqual(first, again)
        # Both requests carry the SAME identifier, which is what makes the
        # second replace the first rather than stack beside it.
        self.assertEqual([first, first],
                         [r.ident for r in self.centre.added])

    def test_two_different_sessions_do_NOT_share_one(self):
        # Asserted because a single module counter that never advanced would
        # pass the test above and collapse every session into one banner.
        a = run(self.t._raise(None, "a", "a"))
        b = run(self.t._raise(None, "b", "b"))
        self.assertNotEqual(a, b)

    def test_the_summary_and_body_reach_the_content(self):
        run(self.t._raise(None, "the summary", "the body"))
        c = self.centre.added[0].content
        self.assertEqual(("the summary", "the body"), (c.title, c.body))

    def test_a_REFUSAL_is_raised_rather_than_swallowed(self):
        # The system's own answer, which is the thing a nil completion
        # handler hides: the probe printed "accepted" while UN was refusing
        # outright. announce() catches this and says so; _raise must not
        # pretend it succeeded.
        self.centre.err = "Notifications are not allowed"
        with self.assertRaises(RuntimeError):
            run(self.t._raise(None, "sum", "body"))

    def test_no_centre_is_an_error_and_not_a_silent_no_op(self):
        t = backend.toaster(None)
        with self.assertRaises(RuntimeError):
            run(t._raise(None, "sum", "body"))


class Withdrawing(unittest.TestCase):
    def setUp(self):
        self.centre = FakeCentre()
        self.t = backend.toaster(self.centre)

    def test_it_withdraws_from_BOTH_lists(self):
        # A banner may be delivered OR still pending and the caller cannot
        # know which, so withdrawing one of the two would leave the other to
        # arrive after the thing it announced is over.
        run(self.t._close(("mux-1", "blocked")))
        self.assertEqual([["mux-1"]], self.centre.delivered_removed)
        self.assertEqual([["mux-1"]], self.centre.pending_removed)

    def test_no_centre_withdraws_nothing_and_does_not_raise(self):
        t = backend.toaster(None)
        run(t._close(("mux-1", "blocked")))


class Inherited(unittest.TestCase):
    """The decisions this backend must NOT have its own copy of.

    Asserted here rather than taken on trust, because a standalone macOS
    toaster was the obvious way to write this and would have been a second
    opinion about when a banner stops being true.
    """

    def test_it_is_a_Toaster(self):
        self.assertIsInstance(backend.toaster(FakeCentre()), sni.Toaster)

    def test_the_wording_is_the_SHARED_one(self):
        t = backend.toaster(FakeCentre())
        self.assertEqual(sni.Toaster(None).text("h", "api", "blocked", True),
                         t.text("h", "api", "blocked", True))

    def test_the_withdrawal_RULES_are_the_shared_ones(self):
        # `stale` is where the four rules live. Inheriting it is the whole
        # argument for subclassing rather than rewriting.
        self.assertIs(sni.Toaster.stale, type(backend.toaster(None)).stale)

    def test_disabled_announces_nothing(self):
        centre = FakeCentre()
        t = backend.toaster(centre, enabled=False)
        self.assertIsNone(run(t.announce("h", None, "api", "blocked")))
        self.assertEqual([], centre.added)


class Completion(unittest.TestCase):
    """`_completed`, which is why a refusal is visible at all."""

    def test_an_error_becomes_an_exception(self):
        with self.assertRaises(RuntimeError):
            run(backend._completed(lambda done: done("refused")))

    def test_no_error_returns_quietly(self):
        run(backend._completed(lambda done: done(None)))


class Dispatch(unittest.TestCase):
    """`sni._backend()` picks by platform, which is the only line in the
    shared half that learns there are two.

    THE DARWIN BRANCH IS REACHED ON LINUX by putting a stand-in in
    sys.modules, because the real one needs PyObjC: the question here is
    which module the dispatch CHOOSES, and importing the answer would make
    this test about the dependency instead.
    """

    def setUp(self):
        self._plat = sys.platform
        self._saved = sni._BACKEND
        sni._BACKEND = None

    def tearDown(self):
        sys.platform = self._plat
        sni._BACKEND = self._saved
        sys.modules.pop("mux_desktop_notifier.backend_appkit_stub", None)

    def test_linux_gets_the_dbus_backend(self):
        sys.platform = "linux"
        self.assertEqual("mux_desktop_notifier.backend_dbus",
                         sni._backend().__name__)

    def test_darwin_gets_the_appkit_backend(self):
        sys.platform = "darwin"
        self.assertEqual("mux_desktop_notifier.backend_appkit",
                         sni._backend().__name__)

    def test_it_is_resolved_ONCE_and_cached(self):
        # The supervisor calls this per item and per toast, so a cache miss
        # would be an import on every tick.
        sys.platform = "linux"
        first = sni._backend()
        sys.platform = "darwin"
        self.assertIs(first, sni._backend())


class ImportsAnywhere(unittest.TestCase):
    """The property the whole file depends on, asserted so it cannot regress.

    A `class X(NSObject)` or a top-level `import AppKit` would make this
    module unimportable off a Mac and take every assertion above with it,
    which is the exact shape the backend split was done to fix.
    """

    def test_no_module_level_appkit_import(self):
        # IT WALKS INTO try/if/with AND STOPS AT FUNCTIONS, which took a
        # planted defect to get right. A first version read only
        # `tree.body`, so it caught a bare top-level `import AppKit` (which
        # the test file's own COLLECTION ERROR already catches, louder) and
        # MISSED the one shape that is both plausible and silent:
        #
        #     try:
        #         import AppKit
        #     except ImportError:
        #         AppKit = None
        #
        # which imports fine here and leaves every AppKit call site reading
        # from None. So the assertion was unkillable in the only direction
        # it was useful for, and passed while that was planted.
        import ast
        import inspect
        banned = {"AppKit", "Foundation", "objc", "UserNotifications"}
        found = set()
        stack = list(ast.parse(inspect.getsource(backend)).body)
        while stack:
            node = stack.pop()
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef,
                                 ast.ClassDef)):
                continue          # deferred on purpose: that IS the pattern
            if isinstance(node, ast.Import):
                found |= {a.name.split(".")[0] for a in node.names}
            elif isinstance(node, ast.ImportFrom):
                found.add((node.module or "").split(".")[0])
            else:
                stack.extend(ast.iter_child_nodes(node))
        self.assertEqual(set(), banned & found,
                         "a platform import outside a function would make "
                         "backend_appkit unimportable off a Mac")

    def test_the_toaster_is_constructible_here(self):
        self.assertIsNotNone(backend.toaster(None, enabled=False))


if __name__ == "__main__":
    unittest.main()
