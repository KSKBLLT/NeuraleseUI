import hashlib
import http.client
import json
import threading
import unittest
import urllib.error
import urllib.request

from update_fixture_server import (
    FIXTURE_PAYLOAD,
    UpdateFixtureServer,
)


class UpdateFixtureServerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.server = UpdateFixtureServer("127.0.0.1", 0)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base_url = self.server.base_url

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)

    def test_metadata_matches_streamed_payload(self) -> None:
        with urllib.request.urlopen(f"{self.base_url}/metadata", timeout=5) as response:
            metadata = json.load(response)
        with urllib.request.urlopen(f"{self.base_url}/payload", timeout=5) as response:
            payload = response.read()

        self.assertEqual(payload, FIXTURE_PAYLOAD)
        self.assertEqual(metadata["size_bytes"], len(FIXTURE_PAYLOAD))
        self.assertEqual(metadata["sha256"], hashlib.sha256(FIXTURE_PAYLOAD).hexdigest())

    def test_failure_modes_are_distinct(self) -> None:
        with self.assertRaises(urllib.error.HTTPError) as not_found:
            urllib.request.urlopen(f"{self.base_url}/not-found", timeout=5)
        self.assertEqual(not_found.exception.code, 404)

        with urllib.request.urlopen(f"{self.base_url}/wrong-size", timeout=5) as response:
            wrong_size = response.read()
        self.assertEqual(len(wrong_size), len(FIXTURE_PAYLOAD) - 17)

        with urllib.request.urlopen(f"{self.base_url}/wrong-sha", timeout=5) as response:
            wrong_sha = response.read()
        self.assertEqual(len(wrong_sha), len(FIXTURE_PAYLOAD))
        self.assertNotEqual(hashlib.sha256(wrong_sha).digest(), hashlib.sha256(FIXTURE_PAYLOAD).digest())

        connection = http.client.HTTPConnection(self.server.server_address[0], self.server.server_address[1], timeout=5)
        connection.request("GET", "/disconnect")
        response = connection.getresponse()
        with self.assertRaises(http.client.IncompleteRead):
            response.read()
        connection.close()


if __name__ == "__main__":
    unittest.main()
