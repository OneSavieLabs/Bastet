from configparser import ConfigParser
import os

class Config():
    def __init__(self):
        self.config = ConfigParser()
        self.config_file_path = os.path.join(os.path.dirname(__file__), 'config.ini')
        self.config.read(self.config_file_path)