export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // Serve the actual app pages and static assets first.
    // The previous placeholder API intercepted "/" and returned JSON,
    // which prevented the homepage from rendering.
    if (env.ASSETS) {
      const assetResponse = await env.ASSETS.fetch(request);
      if (assetResponse.status !== 404) return assetResponse;
    }

    if (url.pathname.startsWith("/api/")) {
      return Response.json({ error: "API endpoint not found" }, { status: 404 });
    }

    return new Response("Page not found", {
      status: 404,
      headers: { "content-type": "text/plain; charset=utf-8" }
    });
  }
};
