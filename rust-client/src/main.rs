use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use matrix_sdk::{
    config::SyncSettings,
    room::Room,
    ruma::{
        events::room::message::{
            MessageType, OriginalSyncRoomMessageEvent, RoomMessageEventContent,
        },
        RoomId, UserId,
    },
    Client, ClientBuilder,
};
use serde_json::json;
use std::env;
use tracing::{info, warn};
use url::Url;

#[derive(Parser)]
#[command(name = "matrix-client")]
#[command(about = "A Matrix client for testing Conduit server")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Login and start sync
    Login {
        #[arg(short, long, default_value = "http://conduit.local")]
        homeserver: String,
        #[arg(short, long)]
        username: String,
        #[arg(short, long)]
        password: String,
    },
    /// Send a message to a room
    Send {
        #[arg(short, long, default_value = "http://conduit.local")]
        homeserver: String,
        #[arg(short, long)]
        username: String,
        #[arg(short, long)]
        password: String,
        #[arg(short, long)]
        room_id: String,
        #[arg(short, long)]
        message: String,
    },
    /// Create a room
    CreateRoom {
        #[arg(short, long, default_value = "http://conduit.local")]
        homeserver: String,
        #[arg(short, long)]
        username: String,
        #[arg(short, long)]
        password: String,
        #[arg(short, long)]
        name: String,
        #[arg(short = 't', long)]
        topic: Option<String>,
    },
    /// List rooms
    ListRooms {
        #[arg(short, long, default_value = "http://conduit.local")]
        homeserver: String,
        #[arg(short, long)]
        username: String,
        #[arg(short, long)]
        password: String,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::init();
    dotenv::dotenv().ok();

    let cli = Cli::parse();

    match cli.command {
        Commands::Login {
            homeserver,
            username,
            password,
        } => {
            login_and_sync(&homeserver, &username, &password).await?;
        }
        Commands::Send {
            homeserver,
            username,
            password,
            room_id,
            message,
        } => {
            send_message(&homeserver, &username, &password, &room_id, &message).await?;
        }
        Commands::CreateRoom {
            homeserver,
            username,
            password,
            name,
            topic,
        } => {
            create_room(&homeserver, &username, &password, &name, topic.as_deref()).await?;
        }
        Commands::ListRooms {
            homeserver,
            username,
            password,
        } => {
            list_rooms(&homeserver, &username, &password).await?;
        }
    }

    Ok(())
}

async fn create_client(homeserver: &str) -> Result<Client> {
    let homeserver_url = Url::parse(homeserver).context("Invalid homeserver URL")?;
    
    let client = ClientBuilder::new()
        .homeserver_url(homeserver_url)
        .build()
        .await
        .context("Failed to create Matrix client")?;

    Ok(client)
}

async fn login_client(client: &Client, username: &str, password: &str) -> Result<()> {
    info!("Logging in as {}", username);
    
    client
        .matrix_auth()
        .login_username(username, password)
        .initial_device_display_name("Conduit Rust Client")
        .await
        .context("Failed to login")?;

    info!("Successfully logged in as {}", username);
    Ok(())
}

async fn login_and_sync(homeserver: &str, username: &str, password: &str) -> Result<()> {
    let client = create_client(homeserver).await?;
    login_client(&client, username, password).await?;

    info!("Starting sync...");
    
    // Set up message handler
    client.add_event_handler(on_room_message);

    // Start syncing
    let sync_settings = SyncSettings::default().token(client.sync_token().await);
    client.sync(sync_settings).await.context("Sync failed")?;

    Ok(())
}

async fn send_message(
    homeserver: &str,
    username: &str,
    password: &str,
    room_id: &str,
    message: &str,
) -> Result<()> {
    let client = create_client(homeserver).await?;
    login_client(&client, username, password).await?;

    let room_id = RoomId::parse(room_id).context("Invalid room ID")?;
    
    if let Some(room) = client.get_room(&room_id) {
        let content = RoomMessageEventContent::text_plain(message);
        
        info!("Sending message to room {}: {}", room_id, message);
        
        room.send(content)
            .await
            .context("Failed to send message")?;
            
        info!("Message sent successfully!");
    } else {
        warn!("Room {} not found", room_id);
    }

    Ok(())
}

async fn create_room(
    homeserver: &str,
    username: &str,
    password: &str,
    name: &str,
    topic: Option<&str>,
) -> Result<()> {
    let client = create_client(homeserver).await?;
    login_client(&client, username, password).await?;

    info!("Creating room: {}", name);
    
    let mut request = matrix_sdk::ruma::api::client::room::create_room::v3::Request::new();
    request.name = Some(name.to_owned());
    
    if let Some(topic) = topic {
        request.topic = Some(topic.to_owned());
    }

    let response = client.create_room(request).await.context("Failed to create room")?;
    
    info!("Room created successfully!");
    info!("Room ID: {}", response.room_id);
    
    println!("Room created: {}", response.room_id);

    Ok(())
}

async fn list_rooms(homeserver: &str, username: &str, password: &str) -> Result<()> {
    let client = create_client(homeserver).await?;
    login_client(&client, username, password).await?;

    info!("Fetching rooms...");
    
    // Do a quick sync to get room list
    let sync_settings = SyncSettings::default().timeout(std::time::Duration::from_secs(5));
    client.sync_once(sync_settings).await.context("Failed to sync")?;

    let rooms = client.rooms();
    
    println!("Found {} rooms:", rooms.len());
    
    for room in rooms {
        match room {
            Room::Joined(joined_room) => {
                let name = joined_room.name().unwrap_or_else(|| "Unnamed Room".to_string());
                println!("  📢 {} ({})", name, joined_room.room_id());
            }
            Room::Invited(invited_room) => {
                println!("  📨 Invited to {}", invited_room.room_id());
            }
            Room::Left(left_room) => {
                println!("  👋 Left {}", left_room.room_id());
            }
        }
    }

    Ok(())
}

async fn on_room_message(event: OriginalSyncRoomMessageEvent, room: Room) {
    if let Room::Joined(room) = room {
        let MessageType::Text(text_content) = &event.content.msgtype else {
            return;
        };

        info!(
            "Message in {}: {} - {}",
            room.room_id(),
            event.sender,
            text_content.body
        );
        
        println!(
            "[{}] {}: {}",
            room.name().unwrap_or_else(|| room.room_id().to_string()),
            event.sender,
            text_content.body
        );
    }
} 