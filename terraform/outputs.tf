output "minecraft_server_ip" {
  description = "Public IP of the Minecraft server"
  value       = aws_instance.minecraft_server.public_ip
}