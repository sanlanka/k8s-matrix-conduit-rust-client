use anyhow::{Context, Result};
use clap::Parser;
use reqwest::Client;
use serde_json::json;
use std::collections::HashMap;
use tracing::{info, warn};

#[derive(Parser)]
#[command(name = "user-setup")]
#[command(about = "Setup admin and test users for Conduit Matrix server")]
struct Cli {
    #[arg(short, long, default_value = "http://conduit.local")]
    homeserver: String,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::init();
    
    let cli = Cli::parse();
    
    setup_users(&cli.homeserver).await?;
    
    Ok(())
}

async fn setup_users(homeserver: &str) -> Result<()> {
    let client = Client::new();
    
    // Test users to create
    let users = vec![
        ("admin", "admin123", "Administrator", true),
        ("bob", "bob123", "Bob Smith", false),
        ("rachel", "rachel123", "Rachel Green", false),
    ];
    
    info!("Setting up users on homeserver: {}", homeserver);
    
    for (username, password, display_name, is_admin) in users {
        match register_user(&client, homeserver, username, password, display_name, is_admin).await {
            Ok(_) => info!("✅ Successfully registered user: {}", username),
            Err(e) => warn!("❌ Failed to register user {}: {}", username, e),
        }
    }
    
    // Create a test room
    if let Err(e) = create_test_room(&client, homeserver).await {
        warn!("Failed to create test room: {}", e);
    }
    
    Ok(())
}

async fn register_user(
    client: &Client,
    homeserver: &str,
    username: &str,
    password: &str,
    display_name: &str,
    is_admin: bool,
) -> Result<()> {
    info!("Registering user: {}", username);
    
    let register_url = format!("{}/_matrix/client/v3/register", homeserver);
    
    let mut auth_data = HashMap::new();
    auth_data.insert("type", "m.login.dummy");
    
    let body = json!({
        "auth": auth_data,
        "username": username,
        "password": password,
        "initial_device_display_name": format!("Conduit Client - {}", display_name),
        "inhibit_login": false
    });
    
    let response = client
        .post(&register_url)
        .header("Content-Type", "application/json")
        .json(&body)
        .send()
        .await
        .context("Failed to send registration request")?;
    
    if response.status().is_success() {
        let response_data: serde_json::Value = response
            .json()
            .await
            .context("Failed to parse registration response")?;
        
        info!("User {} registered with ID: {}", username, response_data["user_id"]);
        
        // Set display name
        if let Err(e) = set_display_name(client, homeserver, &response_data["access_token"].as_str().unwrap_or_default(), display_name).await {
            warn!("Failed to set display name for {}: {}", username, e);
        }
        
        // For now, we'll skip admin privileges as Conduit handles this differently
        if is_admin {
            info!("Note: Admin privileges for {} need to be set via Conduit configuration", username);
        }
        
    } else {
        let error_text = response.text().await.unwrap_or_default();
        
        // Check if user already exists
        if error_text.contains("User ID already taken") || error_text.contains("M_USER_IN_USE") {
            info!("User {} already exists, skipping...", username);
            return Ok(());
        }
        
        return Err(anyhow::anyhow!("Registration failed: {}", error_text));
    }
    
    Ok(())
}

async fn set_display_name(
    client: &Client,
    homeserver: &str,
    access_token: &str,
    display_name: &str,
) -> Result<()> {
    let profile_url = format!("{}/_matrix/client/v3/profile/@{}/displayname", homeserver, "user"); // This would need the actual user ID
    
    let body = json!({
        "displayname": display_name
    });
    
    let _response = client
        .put(&profile_url)
        .header("Authorization", format!("Bearer {}", access_token))
        .header("Content-Type", "application/json")
        .json(&body)
        .send()
        .await
        .context("Failed to set display name")?;
    
    Ok(())
}

async fn create_test_room(client: &Client, homeserver: &str) -> Result<()> {
    info!("Creating test room...");
    
    // First, we need to login as one of the users to create a room
    // Let's use the admin user
    let login_url = format!("{}/_matrix/client/v3/login", homeserver);
    
    let login_body = json!({
        "type": "m.login.password",
        "user": "admin",
        "password": "admin123"
    });
    
    let login_response = client
        .post(&login_url)
        .header("Content-Type", "application/json")
        .json(&login_body)
        .send()
        .await
        .context("Failed to login for room creation")?;
    
    if !login_response.status().is_success() {
        return Err(anyhow::anyhow!("Login failed for room creation"));
    }
    
    let login_data: serde_json::Value = login_response
        .json()
        .await
        .context("Failed to parse login response")?;
    
    let access_token = login_data["access_token"]
        .as_str()
        .context("No access token in login response")?;
    
    // Create the room
    let create_room_url = format!("{}/_matrix/client/v3/createRoom", homeserver);
    
    let room_body = json!({
        "name": "General Discussion",
        "topic": "A test room for general discussion",
        "preset": "public_chat",
        "room_version": "10"
    });
    
    let room_response = client
        .post(&create_room_url)
        .header("Authorization", format!("Bearer {}", access_token))
        .header("Content-Type", "application/json")
        .json(&room_body)
        .send()
        .await
        .context("Failed to create room")?;
    
    if room_response.status().is_success() {
        let room_data: serde_json::Value = room_response
            .json()
            .await
            .context("Failed to parse room creation response")?;
        
        info!("✅ Test room created: {}", room_data["room_id"]);
        println!("🏠 Test room created: {}", room_data["room_id"]);
    } else {
        let error_text = room_response.text().await.unwrap_or_default();
        warn!("Failed to create test room: {}", error_text);
    }
    
    Ok(())
} 