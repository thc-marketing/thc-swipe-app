
export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/") {
      return Response.json({
        girls: [],
        message: "THC live profiles API is running"
      });
    }

    return Response.json({
      error: "Profile not found"
    }, { status: 404 });
  }
};
