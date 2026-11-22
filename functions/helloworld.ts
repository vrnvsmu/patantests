export default {
  fetch() {
    return new Response("TestPatan Neon Function работает!", {
      headers: { "content-type": "text/plain; charset=utf-8" }
    });
  }
};
