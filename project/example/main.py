from app.hello import hello
import time

if __name__ == "__main__":
    print("Starting app...")
    while True:
        hello()
        time.sleep(5)  # выводить сообщение каждые 5 секунд
