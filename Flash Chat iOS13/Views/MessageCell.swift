//
//  MessageCell.swift
//  Flash Chat iOS13
//
//  Created by Bijon Krishna Bairagi on 1/20/25.
//  Copyright © 2025 Angela Yu. All rights reserved.
//

import UIKit

class MessageCell: UITableViewCell {
    @IBOutlet weak var messagebubble: UIView!
    @IBOutlet weak var msgLabel: UILabel!
    
    @IBOutlet weak var leftImageView: UIImageView!
    @IBOutlet weak var rightImageView: UIImageView!
    override func awakeFromNib() {
        super.awakeFromNib()
        messagebubble.layer.cornerRadius = messagebubble.frame.height / 5
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)

        // Configure the view for the selected state
    }
    
}
