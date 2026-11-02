export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // Map the clean profile route to the actual browse page.
    if (url.pathname === "/browse" || url.pathname === "/browse/") {
      url.pathname = "/browse.html";
      request = new Request(url.toString(), request);
    }

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
