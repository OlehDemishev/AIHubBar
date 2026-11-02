//! The real socket: what `claudepult --app-command` sends reaches the app's handler and the answer comes back.

use claudepult_core::ipc::{self, Reply, Request};

#[test]
fn request_and_reply() {
    ipc::serve(|request| match request {
        Request::AppCommand(name) if name == "settings" => Reply::Ok,
        Request::AppCommand(_) => Reply::Unknown,
    })
    .expect("the app side listens");
    assert_eq!(ipc::send(&Request::AppCommand("settings".into())).unwrap(), Reply::Ok);
    assert_eq!(ipc::send(&Request::AppCommand("nothing".into())).unwrap(), Reply::Unknown);
}
