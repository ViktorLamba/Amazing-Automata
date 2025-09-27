from app.hello import hello

def test_hello(capsys):
    hello()
    captured = capsys.readouterr()
    assert "Hello, world!" in captured.out
